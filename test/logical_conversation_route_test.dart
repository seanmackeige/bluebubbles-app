import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _logicalId = 'test-certified-logical-conversation';
const _certificateId = '$logicalConversationOutboundRouteSchema:$_logicalId';
const _backend = 'current-backend';
const _accountSnapshot = 'stable-account-projection';
const _activeSelf = 'sender@example.invalid';
const _otherSelf = 'owner@example.invalid';
const _writableRow = 10;
const _alternateRow = 20;

const _writableParticipants = <LogicalAddressEvidence>[
  LogicalAddressEvidence(address: 'tel:+1 202-555-0101', country: 'US'),
  LogicalAddressEvidence(address: 'mailto:person@example.invalid'),
];

const _alternateParticipants = <LogicalAddressEvidence>[
  LogicalAddressEvidence(address: '(202) 555-0101', country: 'US'),
  LogicalAddressEvidence(address: 'PERSON@EXAMPLE.INVALID'),
  LogicalAddressEvidence(address: _otherSelf),
];

const _currentComcastExternalParticipants = <LogicalAddressEvidence>[
  LogicalAddressEvidence(address: 'tel:+1 202-555-0100', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0101', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0102', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0103', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0104', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0105', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0106', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0107', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0108', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0109', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0110', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0111', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0112', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0113', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0114', country: 'US'),
  LogicalAddressEvidence(address: 'tel:+1 202-555-0115', country: 'US'),
];

LogicalRouteCandidateEvidence _candidate(
  int rowId, {
  List<LogicalAddressEvidence>? participants,
  LogicalAddressEvidence? lastAddressed,
  bool messageSnapshotComplete = true,
  List<LogicalSuccessfulOutboundEvidence>? successfulOutbounds,
  String? sourceGuid,
  int style = 43,
  String sourceService = 'iMessage',
  bool chatSnapshotComplete = true,
  bool? lastKnownHybridState,
  bool? shouldForceToSms = false,
  String? lastSeenMessageGuid = 'last-seen',
  String? groupPhotoGuid,
  List<LogicalRouteMessageEvidence> messages = const [],
}) {
  final writable = rowId == _writableRow;
  return LogicalRouteCandidateEvidence(
    sourceChatRowId: rowId,
    sourceChatGuid: sourceGuid ?? (writable ? 'source-a-guid' : 'source-b-guid'),
    sourceService: sourceService,
    chatIdentifier: writable ? 'source-a-identifier' : 'source-b-identifier',
    style: style,
    lastAddressedHandle: lastAddressed ?? const LogicalAddressEvidence(address: _activeSelf),
    participants: participants ?? (writable ? _writableParticipants : _alternateParticipants),
    chatSnapshotComplete: chatSnapshotComplete,
    messageSnapshotComplete: messageSnapshotComplete,
    lastKnownHybridState: lastKnownHybridState,
    shouldForceToSms: shouldForceToSms,
    lastSeenMessageGuid: lastSeenMessageGuid,
    groupPhotoGuid: groupPhotoGuid,
    messages: messages,
    successfulOutbounds:
        successfulOutbounds ??
        [
          LogicalSuccessfulOutboundEvidence(
            messageGuid: writable ? 'source-a-outbound' : 'source-b-outbound',
            messageRowId: writable ? 101 : 202,
            createdAtEpoch: writable ? 2000 : 1000,
          ),
        ],
  );
}

LogicalRouteEvidence _evidence({
  String logicalId = _logicalId,
  String? certificateId = _certificateId,
  Map<int, String>? certifiedSourceChatGuids,
  String backend = _backend,
  bool detectedIMessage = true,
  bool privateApiConnected = true,
  bool helperConnected = true,
  String accountBefore = _accountSnapshot,
  String accountAfter = _accountSnapshot,
  LogicalAddressEvidence activeSelfAlias = const LogicalAddressEvidence(address: _activeSelf),
  List<LogicalAddressEvidence> vettedSelfAliases = const [
    LogicalAddressEvidence(address: _activeSelf),
    LogicalAddressEvidence(address: _otherSelf),
  ],
  LogicalExecutionGenerationCertificate? executionGenerationCertificate,
  bool candidateScopeSnapshotComplete = true,
  Map<int, String> unadmittedPotentialSourceChatGuids = const {},
  List<LogicalRouteCandidateEvidence>? candidates,
}) => LogicalRouteEvidence(
  logicalId: logicalId,
  certificateId: certificateId,
  certifiedSourceChatGuids:
      certifiedSourceChatGuids ?? const {_writableRow: 'source-a-guid', _alternateRow: 'source-b-guid'},
  backendComputerId: backend,
  detectedIMessage: detectedIMessage,
  privateApiConnected: privateApiConnected,
  helperConnected: helperConnected,
  accountSnapshotBeforeSha256: accountBefore,
  accountSnapshotAfterSha256: accountAfter,
  activeSelfAlias: activeSelfAlias,
  vettedSelfAliases: vettedSelfAliases,
  executionGenerationCertificate: executionGenerationCertificate,
  candidateScopeSnapshotComplete: candidateScopeSnapshotComplete,
  unadmittedPotentialSourceChatGuids: unadmittedPotentialSourceChatGuids,
  candidates: candidates ?? [_candidate(_alternateRow), _candidate(_writableRow)],
);

LogicalRouteDecision _resolve(LogicalMutationRequest request, {LogicalRouteEvidence? evidence}) =>
    LogicalConversationOutboundRoutePolicy.resolve(evidence ?? _evidence(), request);

String _anchorFingerprint(String guid) => sha256.convert(utf8.encode('logical-route-anchor-v1\u0000$guid')).toString();

LogicalRouteMessageEvidence _message(
  String guid,
  int rowId,
  int createdAt, {
  bool isFromMe = false,
  int error = 0,
  int itemType = 0,
  String? associatedMessageGuid,
}) => LogicalRouteMessageEvidence(
  messageGuid: guid,
  messageRowId: rowId,
  createdAtEpoch: createdAt,
  isFromMe: isFromMe,
  error: error,
  itemType: itemType,
  associatedMessageGuid: associatedMessageGuid,
);

LogicalExecutionGenerationCertificate _generationCertificate({
  List<LogicalAddressEvidence> externalParticipants = _writableParticipants,
}) => LogicalExecutionGenerationCertificate(
  schema: logicalExecutionGenerationCertificateSchema,
  logicalId: _logicalId,
  evidenceReceiptCommit: '272fb442c343665459957eaf52b6e61411dd7e3e',
  currentService: 'SMS',
  predecessorService: 'iMessage',
  expectedCurrentMemberCount: 2,
  expectedPredecessorMemberCount: 1,
  expectedExternalParticipantCount: externalParticipants.length,
  expectedExternalParticipantSetSha256: LogicalConversationOutboundRoutePolicy.externalParticipantSetFingerprint(
    externalParticipants
        .map(LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress)
        .whereType<String>()
        .toSet(),
  ),
  predecessorHandoffGuidSha256: _anchorFingerprint('predecessor-terminal'),
  authorizedOutboundGuidSha256: _anchorFingerprint('authorized-anchor'),
  maximumTransitionEdgeDelayMilliseconds: 60,
  maximumNaturalResponseDelayMilliseconds: 900,
  explanation: 'Runtime-shaped generation proof fixture.',
);

LogicalRouteEvidence _generationEvidence({
  List<int> order = const [30, _writableRow, _alternateRow],
  List<LogicalRouteMessageEvidence>? predecessorMessages,
  List<LogicalRouteCandidateEvidence> extraCandidates = const [],
}) {
  final predecessorHistory = predecessorMessages ?? [_message('predecessor-terminal', 301, 1000, isFromMe: true)];
  final candidates = <int, LogicalRouteCandidateEvidence>{
    30: _candidate(
      30,
      sourceGuid: 'predecessor-guid',
      sourceService: 'iMessage',
      participants: _writableParticipants,
      lastSeenMessageGuid: predecessorHistory.last.messageGuid,
      groupPhotoGuid: 'shared-group-photo',
      messages: predecessorHistory,
      successfulOutbounds: [
        LogicalSuccessfulOutboundEvidence(
          messageGuid: predecessorHistory.first.messageGuid,
          messageRowId: predecessorHistory.first.messageRowId,
          createdAtEpoch: predecessorHistory.first.createdAtEpoch,
        ),
      ],
    ),
    _writableRow: _candidate(
      _writableRow,
      sourceGuid: 'current-writable-guid',
      sourceService: 'SMS',
      lastKnownHybridState: true,
      lastSeenMessageGuid: 'current-last',
      groupPhotoGuid: 'shared-group-photo',
      messages: [
        _message('transition-reaction', 101, 1010, associatedMessageGuid: 'p:0/predecessor-terminal'),
        _message('authorized-anchor', 102, 2000, isFromMe: true),
        _message('current-normal', 104, 3000),
        _message('current-last', 103, 5000, associatedMessageGuid: 'p:0/current-relationship-target'),
      ],
      successfulOutbounds: const [
        LogicalSuccessfulOutboundEvidence(messageGuid: 'authorized-anchor', messageRowId: 102, createdAtEpoch: 2000),
      ],
    ),
    _alternateRow: _candidate(
      _alternateRow,
      sourceGuid: 'current-self-variant-guid',
      sourceService: 'SMS',
      lastKnownHybridState: true,
      lastSeenMessageGuid: 'self-variant-last',
      messages: [
        _message('self-variant-outbound', 201, 1500, isFromMe: true),
        _message('natural-response', 202, 2300),
        _message('self-variant-last', 203, 4000),
      ],
      successfulOutbounds: const [
        LogicalSuccessfulOutboundEvidence(
          messageGuid: 'self-variant-outbound',
          messageRowId: 201,
          createdAtEpoch: 1500,
        ),
      ],
    ),
  };
  for (final candidate in extraCandidates) {
    candidates[candidate.sourceChatRowId] = candidate;
  }
  final ordered = [...order.map((rowId) => candidates[rowId]!), ...extraCandidates];
  return _evidence(
    certifiedSourceChatGuids: {for (final candidate in ordered) candidate.sourceChatRowId: candidate.sourceChatGuid},
    executionGenerationCertificate: _generationCertificate(),
    candidates: ordered,
  );
}

LogicalRouteEvidence _advancedGenerationEvidence({
  List<int>? order,
  int predecessorRow = 30,
  int writableRow = _writableRow,
  int selfVariantRow = _alternateRow,
  List<LogicalAddressEvidence> externalParticipants = _writableParticipants,
  List<LogicalAddressEvidence>? certificateExternalParticipants,
  List<LogicalAddressEvidence>? writableParticipants,
  List<LogicalAddressEvidence>? selfVariantParticipants,
  String writableService = 'SMS',
  int predecessorReactivationAt = 6000,
  String crossMemberTarget = 'self-variant-post-reactivation',
  int crossMemberEdgeAt = 7100,
  int crossMemberEdgeError = 0,
  int crossMemberTargetItemType = 0,
  bool includePostAdvancementResponse = true,
}) {
  final candidates = <int, LogicalRouteCandidateEvidence>{
    predecessorRow: _candidate(
      predecessorRow,
      sourceGuid: 'predecessor-guid',
      sourceService: 'iMessage',
      participants: externalParticipants,
      lastSeenMessageGuid: 'reactivated-predecessor',
      groupPhotoGuid: 'shared-group-photo',
      messages: [
        _message('predecessor-terminal', 301, 1000, isFromMe: true),
        _message('reactivated-predecessor', 302, predecessorReactivationAt, isFromMe: true),
      ],
      successfulOutbounds: [
        const LogicalSuccessfulOutboundEvidence(
          messageGuid: 'predecessor-terminal',
          messageRowId: 301,
          createdAtEpoch: 1000,
        ),
        LogicalSuccessfulOutboundEvidence(
          messageGuid: 'reactivated-predecessor',
          messageRowId: 302,
          createdAtEpoch: predecessorReactivationAt,
        ),
      ],
    ),
    writableRow: _candidate(
      writableRow,
      sourceGuid: 'current-writable-guid',
      sourceService: writableService,
      participants: writableParticipants ?? externalParticipants,
      lastKnownHybridState: true,
      lastSeenMessageGuid: 'writable-latest',
      groupPhotoGuid: 'shared-group-photo',
      messages: [
        _message('transition-reaction', 101, 1010, associatedMessageGuid: 'p:0/predecessor-terminal'),
        _message('authorized-anchor', 102, 2000, isFromMe: true),
        _message('current-normal', 103, 3000),
        _message('post-reactivation-outbound', 104, 7000, isFromMe: true),
        _message(
          'current-cross-member-edge',
          105,
          crossMemberEdgeAt,
          error: crossMemberEdgeError,
          associatedMessageGuid: 'p:0/$crossMemberTarget',
        ),
        _message('writable-latest', 106, 9000),
      ],
      successfulOutbounds: const [
        LogicalSuccessfulOutboundEvidence(messageGuid: 'authorized-anchor', messageRowId: 102, createdAtEpoch: 2000),
        LogicalSuccessfulOutboundEvidence(
          messageGuid: 'post-reactivation-outbound',
          messageRowId: 104,
          createdAtEpoch: 7000,
        ),
      ],
    ),
    selfVariantRow: _candidate(
      selfVariantRow,
      sourceGuid: 'current-self-variant-guid',
      sourceService: 'SMS',
      participants:
          selfVariantParticipants ?? [...externalParticipants, const LogicalAddressEvidence(address: _otherSelf)],
      lastKnownHybridState: true,
      lastSeenMessageGuid: 'self-variant-latest',
      messages: [
        _message('self-variant-outbound', 201, 1500, isFromMe: true),
        _message('natural-response', 202, 2300),
        _message('self-variant-post-reactivation', 203, 6900, itemType: crossMemberTargetItemType),
        if (includePostAdvancementResponse) _message('post-reactivation-response', 204, 7200),
        _message('self-variant-latest', 205, 8000),
      ],
      successfulOutbounds: const [
        LogicalSuccessfulOutboundEvidence(
          messageGuid: 'self-variant-outbound',
          messageRowId: 201,
          createdAtEpoch: 1500,
        ),
      ],
    ),
  };
  final ordered = (order ?? [predecessorRow, writableRow, selfVariantRow])
      .map((rowId) => candidates[rowId]!)
      .toList(growable: false);
  return _evidence(
    certifiedSourceChatGuids: {for (final candidate in ordered) candidate.sourceChatRowId: candidate.sourceChatGuid},
    executionGenerationCertificate: _generationCertificate(
      externalParticipants: certificateExternalParticipants ?? externalParticipants,
    ),
    candidates: ordered,
  );
}

void main() {
  group('current execution generation certificate', () {
    const newMessage = LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage);

    test('runtime-shaped provider graph selects one current physical route', () {
      final decision = _resolve(newMessage, evidence: _generationEvidence());
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [_writableRow]);
      expect(decision.reason, 'CURRENT_EXECUTION_GENERATION_PROVEN_UNIQUE_WRITABLE_SOURCE');
    });

    test('candidate ordering cannot alter the proven generation or route', () {
      final forward = _resolve(newMessage, evidence: _generationEvidence());
      final reverse = _resolve(
        newMessage,
        evidence: _generationEvidence(order: const [_alternateRow, _writableRow, 30]),
      );
      expect(reverse.reason, forward.reason);
      expect(reverse.physicalTargetRowIds, forward.physicalTargetRowIds);
    });

    test('predecessor activity without current-generation reproof fails closed', () {
      final evidence = _generationEvidence(
        predecessorMessages: [
          _message('predecessor-terminal', 301, 1000, isFromMe: true),
          _message('resurrected-predecessor', 302, 6000),
        ],
      );
      final decision = _resolve(newMessage, evidence: evidence);
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('current natural Comcast-shaped advancement re-proves exactly one SMS writer', () {
      final decision = _resolve(newMessage, evidence: _advancedGenerationEvidence());
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [_writableRow]);
      expect(
        decision.reason,
        'CURRENT_EXECUTION_GENERATION_REPROVEN_AFTER_PREDECESSOR_ACTIVITY_UNIQUE_WRITABLE_SOURCE',
      );
    });

    test('current public-safe 2027 2155 2156 fixture preserves all 16 external identities', () {
      final evidence = _advancedGenerationEvidence(
        order: const [2155, 2027, 2156],
        predecessorRow: 2027,
        writableRow: 2156,
        selfVariantRow: 2155,
        externalParticipants: _currentComcastExternalParticipants,
      );
      final decision = _resolve(newMessage, evidence: evidence);
      expect(evidence.candidates.map((candidate) => candidate.sourceChatRowId).toSet(), {2027, 2155, 2156});
      expect(evidence.executionGenerationCertificate!.expectedExternalParticipantCount, 16);
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [2156]);
    });

    test('production certificate pins the independently observed current external set', () {
      expect(LogicalConversationOutboundRoutePolicy.comcastNodeUpdatesGeneration.expectedExternalParticipantCount, 16);
      expect(
        LogicalConversationOutboundRoutePolicy.comcastNodeUpdatesGeneration.expectedExternalParticipantSetSha256,
        '7c5deb71cf0ad257a7b708b25ed4c7aa0c0f0f3dfb2e1694ed4f32d60b71e8bc',
      );
    });

    test('current natural Comcast-shaped advancement is input-order invariant', () {
      final forward = _resolve(newMessage, evidence: _advancedGenerationEvidence());
      final reverse = _resolve(
        newMessage,
        evidence: _advancedGenerationEvidence(order: const [_alternateRow, _writableRow, 30]),
      );
      expect(reverse.reason, forward.reason);
      expect(reverse.physicalTargetRowIds, forward.physicalTargetRowIds);
    });

    test('two current writers after predecessor advancement fail closed', () {
      final decision = _resolve(
        newMessage,
        evidence: _advancedGenerationEvidence(selfVariantParticipants: _writableParticipants),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_WRITER_NOT_UNIQUE_AFTER_PREDECESSOR_ADVANCEMENT');
    });

    test('zero current writers after predecessor advancement fail closed', () {
      final decision = _resolve(
        newMessage,
        evidence: _advancedGenerationEvidence(
          writableParticipants: _alternateParticipants,
          selfVariantParticipants: _alternateParticipants,
        ),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'GENERATION_HANDOFF_SOURCE_NOT_WRITABLE');
    });

    test('service-generation conflict after predecessor advancement fails closed', () {
      final decision = _resolve(newMessage, evidence: _advancedGenerationEvidence(writableService: 'iMessage'));
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'UNCLASSIFIED_EXECUTION_GENERATION_MEMBER');
    });

    test('predecessor advancement newer than the current reproof invalidates stale authority', () {
      final decision = _resolve(newMessage, evidence: _advancedGenerationEvidence(predecessorReactivationAt: 9500));
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('cross-member reproof must retain an exact current message target', () {
      final decision = _resolve(
        newMessage,
        evidence: _advancedGenerationEvidence(crossMemberTarget: 'unrelated-or-missing-target'),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_CROSS_MEMBER_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('failed cross-member relationship cannot become advancement proof', () {
      final decision = _resolve(newMessage, evidence: _advancedGenerationEvidence(crossMemberEdgeError: 4));
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_CROSS_MEMBER_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('relationship cannot target a future current-generation message', () {
      final decision = _resolve(newMessage, evidence: _advancedGenerationEvidence(crossMemberEdgeAt: 6800));
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_CROSS_MEMBER_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('relationship target must be authority-bearing natural activity', () {
      final decision = _resolve(newMessage, evidence: _advancedGenerationEvidence(crossMemberTargetItemType: 1));
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_CROSS_MEMBER_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('current writer requires a bounded natural response after predecessor advancement', () {
      final decision = _resolve(
        newMessage,
        evidence: _advancedGenerationEvidence(includePostAdvancementResponse: false),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'CURRENT_GENERATION_NATURAL_RESPONSE_REPROOF_AFTER_PREDECESSOR_ADVANCEMENT_MISSING');
    });

    test('simultaneous certified-member participant co-drift fails the admitted-set digest', () {
      const driftedExternal = <LogicalAddressEvidence>[
        LogicalAddressEvidence(address: 'tel:+1 303-555-0101', country: 'US'),
        LogicalAddressEvidence(address: 'mailto:different@example.invalid'),
      ];
      final decision = _resolve(
        newMessage,
        evidence: _advancedGenerationEvidence(
          externalParticipants: driftedExternal,
          certificateExternalParticipants: _writableParticipants,
        ),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'INTENDED_EXTERNAL_PARTICIPANT_SET_CERTIFICATE_MISMATCH');
    });

    test('predecessor advancement changes the execution authority revision', () {
      expect(_generationEvidence().authorityRevision, isNot(_advancedGenerationEvidence().authorityRevision));
    });

    test('future unadmitted physical identity cannot inherit write authority', () {
      final evidence = _generationEvidence();
      final decision = _resolve(
        newMessage,
        evidence: _evidence(
          certifiedSourceChatGuids: evidence.certifiedSourceChatGuids,
          executionGenerationCertificate: evidence.executionGenerationCertificate,
          unadmittedPotentialSourceChatGuids: const {40: 'future-current-looking-guid'},
          candidates: evidence.candidates,
        ),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'UNADMITTED_POTENTIAL_EXECUTION_GENERATION_PRESENT');
    });

    test('unstable complete-chat scope fails closed', () {
      final evidence = _generationEvidence();
      final decision = _resolve(
        newMessage,
        evidence: _evidence(
          certifiedSourceChatGuids: evidence.certifiedSourceChatGuids,
          executionGenerationCertificate: evidence.executionGenerationCertificate,
          candidateScopeSnapshotComplete: false,
          candidates: evidence.candidates,
        ),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'POTENTIAL_EXECUTION_CANDIDATE_SCOPE_UNSTABLE');
    });

    test('missing provider generation property fails closed', () {
      final evidence = _generationEvidence();
      final candidates = evidence.candidates
          .map(
            (candidate) => candidate.sourceChatRowId == _writableRow
                ? _candidate(
                    _writableRow,
                    sourceGuid: candidate.sourceChatGuid,
                    sourceService: candidate.sourceService,
                    messages: candidate.messages,
                    successfulOutbounds: candidate.successfulOutbounds,
                    lastSeenMessageGuid: candidate.lastSeenMessageGuid,
                    groupPhotoGuid: candidate.groupPhotoGuid,
                  )
                : candidate,
          )
          .toList();
      final decision = _resolve(
        newMessage,
        evidence: _evidence(
          certifiedSourceChatGuids: evidence.certifiedSourceChatGuids,
          executionGenerationCertificate: evidence.executionGenerationCertificate,
          candidates: candidates,
        ),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'UNCLASSIFIED_EXECUTION_GENERATION_MEMBER');
    });

    test('removing the authorized outbound anchor fails closed', () {
      final evidence = _generationEvidence();
      final candidates = evidence.candidates
          .map(
            (candidate) => candidate.sourceChatRowId == _writableRow
                ? _candidate(
                    _writableRow,
                    sourceGuid: candidate.sourceChatGuid,
                    sourceService: candidate.sourceService,
                    lastKnownHybridState: candidate.lastKnownHybridState,
                    lastSeenMessageGuid: candidate.lastSeenMessageGuid,
                    groupPhotoGuid: candidate.groupPhotoGuid,
                    messages: candidate.messages
                        .where((message) => message.messageGuid != 'authorized-anchor')
                        .toList(),
                    successfulOutbounds: const [],
                  )
                : candidate,
          )
          .toList();
      final decision = _resolve(
        newMessage,
        evidence: _evidence(
          certifiedSourceChatGuids: evidence.certifiedSourceChatGuids,
          executionGenerationCertificate: evidence.executionGenerationCertificate,
          candidates: candidates,
        ),
      );
      expect(decision.isQualified, isFalse);
      expect(decision.reason, 'AUTHORIZED_OUTBOUND_GENERATION_ANCHOR_MISSING');
    });
  });

  group('generic new-message and attachment route', () {
    const newMessage = LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage);

    test('normalization proves equality where raw participant subset is unsupported', () {
      final rawWritable = _writableParticipants.map((item) => item.address).toSet();
      final rawAlternate = _alternateParticipants.map((item) => item.address).toSet();
      expect(rawWritable.difference(rawAlternate), isNotEmpty);
      expect(rawAlternate.difference(rawWritable), isNotEmpty);

      Set<String> external(List<LogicalAddressEvidence> values) => values
          .map(LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress)
          .whereType<String>()
          .where((value) => value != 'EMAIL:${_otherSelf.toLowerCase()}')
          .toSet();
      expect(external(_writableParticipants), external(_alternateParticipants));
    });

    test('qualified provenance resolves exactly one physical source', () {
      final decision = _resolve(newMessage);
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [_writableRow]);
      expect(decision.reason, 'UNIQUE_CURRENT_PROVENANCE_WRITABLE_SOURCE');
    });

    test('physical input order and UI render order do not alter execution target', () {
      final forward = _resolve(
        newMessage,
        evidence: _evidence(candidates: [_candidate(_writableRow), _candidate(_alternateRow)]),
      );
      final reverse = _resolve(
        newMessage,
        evidence: _evidence(candidates: [_candidate(_alternateRow), _candidate(_writableRow)]),
      );
      expect(forward.physicalTargetRowIds, reverse.physicalTargetRowIds);
      expect(forward.physicalTargetRowIds, [_writableRow]);
    });

    test('highest ROWID is not selected', () {
      expect(_alternateRow, greaterThan(_writableRow));
      expect(_resolve(newMessage).physicalTargetRowIds, [_writableRow]);
    });

    test('most recent message alone cannot select between equally eligible sources', () {
      final result = _resolve(
        newMessage,
        evidence: _evidence(
          candidates: [
            _candidate(_writableRow),
            _candidate(_alternateRow, participants: _writableParticipants),
          ],
        ),
      );
      expect(result.reason, 'AMBIGUOUS_WRITE_ELIGIBLE_SOURCE');
    });

    test('three-member read certificate does not grant write authority to two eligible sources', () {
      final third = _candidate(
        30,
        sourceGuid: 'source-c-guid',
        participants: _writableParticipants,
        successfulOutbounds: const [
          LogicalSuccessfulOutboundEvidence(messageGuid: 'source-c-outbound', messageRowId: 303, createdAtEpoch: 3000),
        ],
      );
      final candidates = [_candidate(_alternateRow), _candidate(_writableRow), third];
      final evidence = _evidence(
        certifiedSourceChatGuids: const {
          _writableRow: 'source-a-guid',
          _alternateRow: 'source-b-guid',
          30: 'source-c-guid',
        },
        candidates: candidates,
      );
      final forward = _resolve(newMessage, evidence: evidence);
      final reverse = _resolve(
        newMessage,
        evidence: _evidence(
          certifiedSourceChatGuids: evidence.certifiedSourceChatGuids,
          candidates: candidates.reversed.toList(),
        ),
      );
      expect(forward.isQualified, isFalse);
      expect(forward.reason, 'ROUTE_NOT_PROVEN_EXPANDED_SET_AMBIGUOUS');
      expect(reverse.reason, forward.reason);
      expect(forward.physicalTargetRowIds, isEmpty);
    });

    test('selected source requires successful provenance newer than stale alternative provenance', () {
      final noProvenance = _resolve(
        newMessage,
        evidence: _evidence(
          candidates: [
            _candidate(_writableRow, successfulOutbounds: const []),
            _candidate(_alternateRow),
          ],
        ),
      );
      expect(noProvenance.reason, 'NO_SUCCESSFUL_WRITABLE_SOURCE_PROVENANCE');

      final contradicted = _resolve(
        newMessage,
        evidence: _evidence(
          candidates: [
            _candidate(
              _writableRow,
              successfulOutbounds: const [
                LogicalSuccessfulOutboundEvidence(messageGuid: 'a-old', messageRowId: 1, createdAtEpoch: 1000),
              ],
            ),
            _candidate(
              _alternateRow,
              successfulOutbounds: const [
                LogicalSuccessfulOutboundEvidence(messageGuid: 'b-new', messageRowId: 2, createdAtEpoch: 2000),
              ],
            ),
          ],
        ),
      );
      expect(contradicted.reason, 'CURRENT_OUTBOUND_PROVENANCE_CONTRADICTION');
    });

    test('unattached attachment uses one proven writable source', () {
      const request = LogicalMutationRequest(mutationClass: LogicalMutationClass.attachment);
      expect(_resolve(request).physicalTargetRowIds, [_writableRow]);
    });

    test('attachment retry cannot reuse a certified source after authority moved', () {
      const retry = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'source-b-guid',
        isRetry: true,
      );
      expect(_resolve(retry).physicalTargetRowIds, isEmpty);
      expect(_resolve(retry).reason, 'PERSISTED_ATTACHMENT_ROUTE_NO_LONGER_AUTHORITATIVE');
    });

    test('attachment retry may reuse only the freshly authoritative source', () {
      const retry = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _writableRow,
        persistedExecutionSourceChatGuid: 'source-a-guid',
        isRetry: true,
      );
      expect(_resolve(retry).physicalTargetRowIds, [_writableRow]);
      expect(_resolve(retry).reason, 'CERTIFIED_PERSISTED_ATTACHMENT_RETRY_ROUTE');
    });

    test('attachment route hint cannot select a source outside an explicit retry', () {
      const initial = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'source-b-guid',
      );
      expect(_resolve(initial).reason, 'UNTRUSTED_ATTACHMENT_EXECUTION_HINT');
    });

    test('wrong-source persisted attachment route fails closed', () {
      const retry = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'source-a-guid',
        isRetry: true,
      );
      expect(_resolve(retry).reason, 'PERSISTED_ATTACHMENT_ROUTE_CONTRADICTION');
    });
  });

  group('fail-closed current source qualification', () {
    const request = LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage);

    test('missing or mismatched equivalence certificate blocks mutation', () {
      expect(_resolve(request, evidence: _evidence(certificateId: null)).reason, 'MISSING_EQUIVALENCE_CERTIFICATE');
      expect(
        _resolve(request, evidence: _evidence(certificateId: 'unbound-certificate')).reason,
        'EQUIVALENCE_CERTIFICATE_BINDING_MISMATCH',
      );
      expect(
        _resolve(request, evidence: _evidence(logicalId: 'future-apparent-duplicate')).state,
        LogicalRouteState.routeNotProven,
      );
    });

    test('zero, missing, extra, or duplicate candidates remain unqualified', () {
      final cases = <List<LogicalRouteCandidateEvidence>>[
        const [],
        [_candidate(_writableRow)],
        [_candidate(_writableRow), _candidate(_alternateRow), _candidate(30)],
        [_candidate(_writableRow), _candidate(_writableRow)],
      ];
      for (final candidates in cases) {
        expect(_resolve(request, evidence: _evidence(candidates: candidates)).state, LogicalRouteState.routeNotProven);
      }
    });

    test('different external participant set blocks mutation', () {
      final result = _resolve(
        request,
        evidence: _evidence(
          candidates: [
            _candidate(
              _writableRow,
              participants: const [
                LogicalAddressEvidence(address: '+1 202-555-0101'),
                LogicalAddressEvidence(address: 'wrong@example.invalid'),
              ],
            ),
            _candidate(_alternateRow),
          ],
        ),
      );
      expect(result.reason, 'EXTERNAL_PARTICIPANT_IDENTITY_CONTRADICTION');
    });

    test('account snapshot instability and active sender contradiction block mutation', () {
      expect(
        _resolve(request, evidence: _evidence(accountAfter: 'changed-account')).reason,
        'CURRENT_ACCOUNT_IDENTITY_UNSTABLE',
      );
      expect(
        _resolve(
          request,
          evidence: _evidence(activeSelfAlias: const LogicalAddressEvidence(address: 'unknown@example.invalid')),
        ).reason,
        'ACTIVE_SENDER_NOT_CURRENT_VETTED_ALIAS',
      );
    });

    test('stale sender route, missing backend, and transport contradiction block mutation', () {
      final stale = _resolve(
        request,
        evidence: _evidence(
          candidates: [
            _candidate(_writableRow, lastAddressed: const LogicalAddressEvidence(address: 'stale@example.invalid')),
            _candidate(_alternateRow),
          ],
        ),
      );
      expect(stale.reason, 'STALE_OR_CONFLICTING_CURRENT_ROUTE');
      expect(_resolve(request, evidence: _evidence(backend: '')).reason, 'BACKEND_IDENTITY_MISSING');
      expect(
        _resolve(request, evidence: _evidence(privateApiConnected: false)).reason,
        'CURRENT_TRANSPORT_CONTEXT_UNPROVEN',
      );
    });

    test('incomplete history, wrong source binding, and opaque identity fail closed', () {
      expect(
        _resolve(
          request,
          evidence: _evidence(
            candidates: [_candidate(_writableRow, messageSnapshotComplete: false), _candidate(_alternateRow)],
          ),
        ).reason,
        'CURRENT_MESSAGE_PROVENANCE_INCOMPLETE',
      );
      expect(
        _resolve(
          request,
          evidence: _evidence(certifiedSourceChatGuids: const {_writableRow: 'wrong', _alternateRow: 'source-b-guid'}),
        ).reason,
        'CURRENT_SOURCE_BINDING_CONTRADICTION',
      );
      expect(
        _resolve(
          request,
          evidence: _evidence(
            candidates: [
              _candidate(
                _writableRow,
                participants: const [
                  LogicalAddressEvidence(address: 'not-a-routable-identity'),
                  LogicalAddressEvidence(address: 'person@example.invalid'),
                ],
              ),
              _candidate(_alternateRow),
            ],
          ),
        ).reason,
        'PARTICIPANT_IDENTITY_UNPROVEN',
      );
    });

    test('typed address normalization is conservative and deterministic', () {
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(address: 'mailto:PERSON@Example.Invalid'),
        ),
        'EMAIL:person@example.invalid',
      );
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(address: '(202) 555-0101', country: 'US'),
        ),
        'PHONE:+12025550101',
      );
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(address: '+44 20 7946 0958', country: 'GB'),
        ),
        'PHONE:+442079460958',
      );
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(address: 'opaque-handle'),
        ),
        isNull,
      );
    });

    test('unsupported logical mutation is bounded', () {
      const unsupported = LogicalMutationRequest(mutationClass: LogicalMutationClass.unsupported);
      expect(_resolve(unsupported).reason, 'UNSUPPORTED_LOGICAL_MUTATION');
    });
  });

  group('provenance-sensitive mutations', () {
    test('reply retains exact target message identity and source route', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'source-b-guid',
      );
      expect(_resolve(reply).physicalTargetRowIds, [_alternateRow]);
    });

    test('reply route does not depend on new-message source selection', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'source-b-guid',
      );
      final ambiguousWriters = _evidence(
        candidates: [
          _candidate(_writableRow),
          _candidate(_alternateRow, participants: _writableParticipants),
        ],
      );
      expect(_resolve(reply, evidence: ambiguousWriters).physicalTargetRowIds, [_alternateRow]);
    });

    test('cross-chat reply cannot be rebound to the new-message route', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'source-a-guid',
      );
      expect(_resolve(reply).reason, 'TARGET_MESSAGE_SOURCE_BINDING_MISMATCH');
    });

    test('reaction retains exact target message identity and source route', () {
      const reaction = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reaction,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _writableRow,
        targetSourceChatGuid: 'source-a-guid',
      );
      expect(_resolve(reaction).physicalTargetRowIds, [_writableRow]);
    });

    test('attachment reply preserves exact target provenance', () {
      const attachmentReply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'source-b-guid',
      );
      expect(_resolve(attachmentReply).physicalTargetRowIds, [_alternateRow]);
    });

    test('generation-bound relationship cannot execute through historical member', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'predecessor-terminal',
        targetSourceChatRowId: 30,
        targetSourceChatGuid: 'predecessor-guid',
        requireFreshTargetPresence: true,
      );
      expect(
        _resolve(reply, evidence: _generationEvidence()).reason,
        'RELATIONSHIP_TARGET_NOT_IN_CURRENT_EXECUTION_GENERATION',
      );
    });

    test('generation-bound relationship retains exact current-member route', () {
      const reaction = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reaction,
        targetMessageGuid: 'self-variant-last',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'current-self-variant-guid',
        requireFreshTargetPresence: true,
      );
      expect(_resolve(reaction, evidence: _generationEvidence()).physicalTargetRowIds, [_alternateRow]);
    });

    test('execution-boundary reply requires the exact target in fresh provider evidence', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'source-b-guid',
        replyIntentMessageGuid: 'selected-reply-message',
        replyIntentSourceChatRowId: _alternateRow,
        replyIntentSourceChatGuid: 'source-b-guid',
        requireFreshTargetPresence: true,
      );
      final evidence = _evidence(
        candidates: [
          _candidate(_writableRow),
          _candidate(
            _alternateRow,
            messages: [_message('target-message', 301, 1000), _message('selected-reply-message', 302, 1100)],
          ),
        ],
      );
      expect(_resolve(reply, evidence: evidence).physicalTargetRowIds, [_alternateRow]);
    });

    test('execution-boundary reply fails closed when target vanished or is duplicated', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'source-b-guid',
        requireFreshTargetPresence: true,
      );
      final missing = _evidence(
        candidates: [
          _candidate(_writableRow),
          _candidate(_alternateRow, messages: const []),
        ],
      );
      final duplicated = _evidence(
        candidates: [
          _candidate(_writableRow),
          _candidate(
            _alternateRow,
            messages: [_message('target-message', 301, 1000), _message('target-message', 302, 1100)],
          ),
        ],
      );
      expect(_resolve(reply, evidence: missing).reason, 'TARGET_MESSAGE_NOT_EXACTLY_PRESENT');
      expect(_resolve(reply, evidence: duplicated).reason, 'TARGET_MESSAGE_NOT_EXACTLY_PRESENT');
    });

    test('execution-boundary reply retains selected-message provenance separately from relationship target', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'root-message',
        targetSourceChatRowId: _writableRow,
        targetSourceChatGuid: 'source-a-guid',
        replyIntentMessageGuid: 'selected-reply-message',
        replyIntentSourceChatRowId: _alternateRow,
        replyIntentSourceChatGuid: 'source-b-guid',
        requireFreshTargetPresence: true,
      );
      final evidence = _evidence(
        candidates: [
          _candidate(_writableRow, messages: [_message('root-message', 301, 1000)]),
          _candidate(_alternateRow, messages: [_message('selected-reply-message', 302, 1100)]),
        ],
      );
      final decision = _resolve(reply, evidence: evidence);
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [_writableRow]);
    });

    test('missing target identity never guesses', () {
      const reply = LogicalMutationRequest(mutationClass: LogicalMutationClass.reply);
      expect(_resolve(reply).reason, 'TARGET_MESSAGE_PROVENANCE_MISSING');
    });
  });

  group('read state and exactly-once admission', () {
    test('mark read touches only represented unread physical sources', () {
      const oneUnread = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {_alternateRow},
      );
      const bothUnread = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {_alternateRow, _writableRow},
      );
      expect(_resolve(oneUnread).physicalTargetRowIds, [_alternateRow]);
      expect(_resolve(bothUnread).physicalTargetRowIds, [_writableRow, _alternateRow]);
    });

    test('read state is independent of ambiguous new-message selection', () {
      const oneUnread = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {_alternateRow},
      );
      final ambiguousWriters = _evidence(
        candidates: [
          _candidate(_writableRow),
          _candidate(_alternateRow, participants: _writableParticipants),
        ],
      );
      expect(_resolve(oneUnread, evidence: ambiguousWriters).physicalTargetRowIds, [_alternateRow]);
    });

    test('already-read performs no mutation and foreign unread source fails', () {
      const alreadyRead = LogicalMutationRequest(mutationClass: LogicalMutationClass.markRead);
      const foreign = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {999},
      );
      expect(_resolve(alreadyRead).physicalTargetRowIds, isEmpty);
      expect(_resolve(foreign).reason, 'UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
    });

    test('one action is admitted once across rebuild, rerender, and double tap', () {
      final gate = LogicalExecutionAdmissionGate();
      expect(gate.admit('action-1'), isTrue);
      expect(gate.admit('action-1'), isFalse);
      expect(gate.admit('action-1'), isFalse);
      expect(gate.admit('action-2'), isTrue);
    });

    test('retry namespace cannot re-admit the same logical action', () {
      final gate = LogicalExecutionAdmissionGate();
      expect(gate.admit('retry-id'), isTrue);
      expect(gate.admit('retry-id', explicitRetry: true), isFalse);
      expect(gate.admit('retry-id', explicitRetry: true), isFalse);
    });

    test('intact pre-dispatch batch rollback permits one fresh re-admission', () {
      final gate = LogicalExecutionAdmissionGate();
      expect(gate.admitBatch(const ['batch-a', 'batch-b']), isTrue);
      expect(gate.rollbackBatch(const ['batch-a', 'batch-b']), isTrue);
      expect(gate.admitBatch(const ['batch-a', 'batch-b']), isTrue);
      expect(gate.rollbackBatch(const ['batch-a', 'missing']), isFalse);
    });

    test('empty action identity is never admitted', () {
      expect(LogicalExecutionAdmissionGate().admit(''), isFalse);
    });
  });
}
