import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:flutter_test/flutter_test.dart';

const _logicalId = 'test-certified-logical-conversation';
const _certificateId = 'test-route-certificate';
const _backend = 'current-backend';
const _account = 'current-account';
const _lastAddressed = 'current-sender';
const _canonicalRow = 10;
const _alternateRow = 20;

final _certificate = LogicalConversationOutboundRouteCertificate(
  id: _certificateId,
  logicalId: _logicalId,
  acceptedBackendComputerIdSha256: LogicalConversationOutboundRoutePolicy.sha256Text(_backend),
  acceptedAccountIdentitySha256: LogicalConversationOutboundRoutePolicy.sha256Text(_account),
  acceptedLastAddressedHandleSha256: LogicalConversationOutboundRoutePolicy.sha256Text(_lastAddressed),
  canonicalNewMessageSourceChatRowId: _canonicalRow,
  sourceBindings: {
    _canonicalRow: LogicalRouteSourceBinding(
      sourceChatRowId: _canonicalRow,
      sourceChatGuidSha256: LogicalConversationOutboundRoutePolicy.sha256Text('canonical-guid'),
      chatIdentifierSha256: LogicalConversationOutboundRoutePolicy.sha256Text('canonical-identifier'),
      participantSetSha256: LogicalConversationOutboundRoutePolicy.participantSetSha256(const {'a', 'b'}),
      successfulOutboundAnchorGuidSha256: LogicalConversationOutboundRoutePolicy.sha256Text('canonical-anchor'),
      successfulOutboundAnchorRowId: 100,
      minimumSuccessfulOutboundCount: 1,
    ),
    _alternateRow: LogicalRouteSourceBinding(
      sourceChatRowId: _alternateRow,
      sourceChatGuidSha256: LogicalConversationOutboundRoutePolicy.sha256Text('alternate-guid'),
      chatIdentifierSha256: LogicalConversationOutboundRoutePolicy.sha256Text('alternate-identifier'),
      participantSetSha256: LogicalConversationOutboundRoutePolicy.participantSetSha256(const {'a', 'b', 'self'}),
      successfulOutboundAnchorGuidSha256: LogicalConversationOutboundRoutePolicy.sha256Text('alternate-anchor'),
      successfulOutboundAnchorRowId: 200,
      minimumSuccessfulOutboundCount: 1,
    ),
  },
);

LogicalRouteCandidateEvidence _candidate(
  int rowId, {
  Set<String>? participants,
  String account = _account,
  bool includeAnchor = true,
  String? lastAddressed,
}) {
  final canonical = rowId == _canonicalRow;
  return LogicalRouteCandidateEvidence(
    sourceChatRowId: rowId,
    sourceChatGuid: canonical ? 'canonical-guid' : 'alternate-guid',
    chatIdentifier: canonical ? 'canonical-identifier' : 'alternate-identifier',
    style: 43,
    lastAddressedHandle: lastAddressed ?? _lastAddressed,
    participantAddresses: participants ?? (canonical ? const {'a', 'b'} : const {'a', 'b', 'self'}),
    accountIdentity: account,
    successfulOutbounds: includeAnchor
        ? [
            LogicalSuccessfulOutboundEvidence(
              messageGuid: canonical ? 'canonical-anchor' : 'alternate-anchor',
              messageRowId: canonical ? 100 : 200,
            ),
          ]
        : const [],
  );
}

LogicalRouteEvidence _evidence({
  String logicalId = _logicalId,
  String? certificateId = _certificateId,
  String backend = _backend,
  bool detectedIMessage = true,
  bool privateApiConnected = true,
  bool helperConnected = true,
  LogicalStaleRouteState staleRouteState = LogicalStaleRouteState.absentCurrentAccepted,
  List<LogicalRouteCandidateEvidence>? candidates,
}) => LogicalRouteEvidence(
  logicalId: logicalId,
  certificateId: certificateId,
  backendComputerId: backend,
  detectedIMessage: detectedIMessage,
  privateApiConnected: privateApiConnected,
  helperConnected: helperConnected,
  staleRouteState: staleRouteState,
  candidates: candidates ?? [_candidate(_alternateRow), _candidate(_canonicalRow)],
);

LogicalRouteDecision _resolve(LogicalMutationRequest request, {LogicalRouteEvidence? evidence}) =>
    LogicalConversationOutboundRoutePolicy.resolve(evidence ?? _evidence(), request, routeCertificate: _certificate);

void main() {
  group('certified new-message and attachment route', () {
    const newMessage = LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage);

    test('golden route resolves to exactly one certificate-selected physical chat', () {
      final decision = _resolve(newMessage);
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [_canonicalRow]);
    });

    test('physical input order and render order cannot alter execution target', () {
      final forward = _resolve(newMessage, evidence: _evidence(candidates: [_candidate(10), _candidate(20)]));
      final reverse = _resolve(newMessage, evidence: _evidence(candidates: [_candidate(20), _candidate(10)]));
      expect(forward.physicalTargetRowIds, reverse.physicalTargetRowIds);
      expect(forward.physicalTargetRowIds, [_canonicalRow]);
    });

    test('highest ROWID is not selected and recency is not an input', () {
      expect(_alternateRow, greaterThan(_canonicalRow));
      expect(_resolve(newMessage).physicalTargetRowIds, [_canonicalRow]);
    });

    test('successful outbound anchors are required; latest-message shape alone is insufficient', () {
      final result = _resolve(
        newMessage,
        evidence: _evidence(candidates: [_candidate(10, includeAnchor: false), _candidate(20)]),
      );
      expect(result.state, LogicalRouteState.routeNotProven);
      expect(result.reason, 'ACCEPTED_SUCCESSFUL_OUTBOUND_PROVENANCE_MISSING');
    });

    test('unattached attachment uses one canonical route', () {
      const request = LogicalMutationRequest(mutationClass: LogicalMutationClass.attachment);
      expect(_resolve(request).physicalTargetRowIds, [_canonicalRow]);
    });

    test('failed attachment retry remains pinned to its certified persisted physical route', () {
      const retry = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'alternate-guid',
        isRetry: true,
      );
      expect(_resolve(retry).physicalTargetRowIds, [_alternateRow]);
      expect(_resolve(retry).reason, 'CERTIFIED_PERSISTED_ATTACHMENT_RETRY_ROUTE');
    });

    test('attachment execution hints cannot select a route outside an explicit retry', () {
      const initial = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'alternate-guid',
      );
      expect(_resolve(initial).reason, 'UNTRUSTED_ATTACHMENT_EXECUTION_HINT');
    });

    test('contradictory persisted attachment retry route fails closed', () {
      const retry = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'canonical-guid',
        isRetry: true,
      );
      expect(_resolve(retry).reason, 'PERSISTED_ATTACHMENT_ROUTE_CONTRADICTION');
    });
  });

  group('fail-closed qualification', () {
    const request = LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage);

    test('stale or unknown route evidence cannot qualify', () {
      for (final stale in [LogicalStaleRouteState.present, LogicalStaleRouteState.unknown]) {
        expect(_resolve(request, evidence: _evidence(staleRouteState: stale)).state, LogicalRouteState.routeNotProven);
      }
    });

    test('missing or mismatched equivalence certificate blocks mutation', () {
      expect(_resolve(request, evidence: _evidence(certificateId: null)).state, LogicalRouteState.routeNotProven);
      expect(
        _resolve(request, evidence: _evidence(logicalId: 'uncertified-apparent-duplicate')).state,
        LogicalRouteState.routeNotProven,
      );
    });

    test('zero, missing, extra, or duplicate candidates remain ambiguous', () {
      final cases = <List<LogicalRouteCandidateEvidence>>[
        const [],
        [_candidate(10)],
        [_candidate(10), _candidate(20), _candidate(20)],
        [_candidate(10), _candidate(10)],
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
            _candidate(10, participants: {'a', 'wrong'}),
            _candidate(20),
          ],
        ),
      );
      expect(result.state, LogicalRouteState.routeNotProven);
    });

    test('conflicting account identity blocks mutation', () {
      final result = _resolve(
        request,
        evidence: _evidence(
          candidates: [
            _candidate(10),
            _candidate(20, account: 'other-account'),
          ],
        ),
      );
      expect(result.reason, 'CONFLICTING_OR_MISSING_ACCOUNT_IDENTITY');
    });

    test('backend, sender, or transport contradiction blocks mutation', () {
      expect(_resolve(request, evidence: _evidence(backend: 'other')).state, LogicalRouteState.routeNotProven);
      expect(
        _resolve(
          request,
          evidence: _evidence(
            candidates: [
              _candidate(10, lastAddressed: 'other'),
              _candidate(20),
            ],
          ),
        ).state,
        LogicalRouteState.routeNotProven,
      );
      expect(_resolve(request, evidence: _evidence(helperConnected: false)).state, LogicalRouteState.routeNotProven);
    });

    test('unsupported logical mutation is bounded', () {
      const unsupported = LogicalMutationRequest(mutationClass: LogicalMutationClass.unsupported);
      expect(_resolve(unsupported).reason, 'UNSUPPORTED_LOGICAL_MUTATION');
    });
  });

  group('provenance-sensitive mutations', () {
    test('reply retains exact target identity and source route', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'alternate-guid',
      );
      expect(_resolve(reply).physicalTargetRowIds, [_alternateRow]);
    });

    test('cross-chat reply cannot be rebound to canonical route', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'canonical-guid',
      );
      expect(_resolve(reply).reason, 'TARGET_MESSAGE_SOURCE_BINDING_MISMATCH');
    });

    test('reaction retains exact target message identity and route', () {
      const reaction = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reaction,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _canonicalRow,
        targetSourceChatGuid: 'canonical-guid',
      );
      expect(_resolve(reaction).physicalTargetRowIds, [_canonicalRow]);
    });

    test('attachment reply preserves target provenance', () {
      const attachmentReply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        targetMessageGuid: 'target-message',
        targetSourceChatRowId: _alternateRow,
        targetSourceChatGuid: 'alternate-guid',
      );
      expect(_resolve(attachmentReply).physicalTargetRowIds, [_alternateRow]);
    });

    test('missing target identity never guesses', () {
      const reply = LogicalMutationRequest(mutationClass: LogicalMutationClass.reply);
      expect(_resolve(reply).reason, 'TARGET_MESSAGE_PROVENANCE_MISSING');
    });
  });

  group('read-state and exactly-once admission', () {
    test('logical mark-read touches only represented unread physical sources', () {
      const oneUnread = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {_alternateRow},
      );
      const bothUnread = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {_alternateRow, _canonicalRow},
      );
      expect(_resolve(oneUnread).physicalTargetRowIds, [_alternateRow]);
      expect(_resolve(bothUnread).physicalTargetRowIds, [_canonicalRow, _alternateRow]);
    });

    test('already-read performs zero mutations and foreign unread source fails', () {
      const alreadyRead = LogicalMutationRequest(mutationClass: LogicalMutationClass.markRead);
      const foreign = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.markRead,
        unreadSourceChatRowIds: {999},
      );
      expect(_resolve(alreadyRead).physicalTargetRowIds, isEmpty);
      expect(_resolve(foreign).state, LogicalRouteState.routeNotProven);
    });

    test('one action is admitted once across rebuild, rerender, and double tap', () {
      final gate = LogicalExecutionAdmissionGate();
      expect(gate.admit('action-1'), isTrue);
      expect(gate.admit('action-1'), isFalse);
      expect(gate.admit('action-1'), isFalse);
      expect(gate.admit('action-2'), isTrue);
    });

    test('explicit user retry reuses existing execution path without broadening route', () {
      final gate = LogicalExecutionAdmissionGate();
      expect(gate.admit('retry-id'), isTrue);
      expect(gate.admit('retry-id', explicitRetry: true), isTrue);
      expect(gate.admit('retry-id', explicitRetry: true), isFalse);
      expect(
        _resolve(const LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage)).isSingleTarget,
        isTrue,
      );
    });

    test('empty action identity is never admitted', () {
      expect(LogicalExecutionAdmissionGate().admit(''), isFalse);
    });
  });
}
