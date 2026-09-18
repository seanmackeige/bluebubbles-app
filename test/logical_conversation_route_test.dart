import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
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

LogicalRouteCandidateEvidence _candidate(
  int rowId, {
  List<LogicalAddressEvidence>? participants,
  LogicalAddressEvidence? lastAddressed,
  bool messageSnapshotComplete = true,
  List<LogicalSuccessfulOutboundEvidence>? successfulOutbounds,
  String? sourceGuid,
  int style = 43,
}) {
  final writable = rowId == _writableRow;
  return LogicalRouteCandidateEvidence(
    sourceChatRowId: rowId,
    sourceChatGuid:
        sourceGuid ?? (writable ? 'source-a-guid' : 'source-b-guid'),
    chatIdentifier: writable ? 'source-a-identifier' : 'source-b-identifier',
    style: style,
    lastAddressedHandle:
        lastAddressed ?? const LogicalAddressEvidence(address: _activeSelf),
    participants:
        participants ??
        (writable ? _writableParticipants : _alternateParticipants),
    messageSnapshotComplete: messageSnapshotComplete,
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
  LogicalAddressEvidence activeSelfAlias = const LogicalAddressEvidence(
    address: _activeSelf,
  ),
  List<LogicalAddressEvidence> vettedSelfAliases = const [
    LogicalAddressEvidence(address: _activeSelf),
    LogicalAddressEvidence(address: _otherSelf),
  ],
  List<LogicalRouteCandidateEvidence>? candidates,
}) => LogicalRouteEvidence(
  logicalId: logicalId,
  certificateId: certificateId,
  certifiedSourceChatGuids:
      certifiedSourceChatGuids ??
      const {_writableRow: 'source-a-guid', _alternateRow: 'source-b-guid'},
  backendComputerId: backend,
  detectedIMessage: detectedIMessage,
  privateApiConnected: privateApiConnected,
  helperConnected: helperConnected,
  accountSnapshotBeforeSha256: accountBefore,
  accountSnapshotAfterSha256: accountAfter,
  activeSelfAlias: activeSelfAlias,
  vettedSelfAliases: vettedSelfAliases,
  candidates:
      candidates ?? [_candidate(_alternateRow), _candidate(_writableRow)],
);

LogicalRouteDecision _resolve(
  LogicalMutationRequest request, {
  LogicalRouteEvidence? evidence,
}) => LogicalConversationOutboundRoutePolicy.resolve(
  evidence ?? _evidence(),
  request,
);

void main() {
  group('generic new-message and attachment route', () {
    const newMessage = LogicalMutationRequest(
      mutationClass: LogicalMutationClass.newMessage,
    );

    test(
      'normalization proves equality where raw participant subset is unsupported',
      () {
        final rawWritable = _writableParticipants
            .map((item) => item.address)
            .toSet();
        final rawAlternate = _alternateParticipants
            .map((item) => item.address)
            .toSet();
        expect(rawWritable.difference(rawAlternate), isNotEmpty);
        expect(rawAlternate.difference(rawWritable), isNotEmpty);

        Set<String> external(List<LogicalAddressEvidence> values) => values
            .map(
              LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress,
            )
            .whereType<String>()
            .where((value) => value != 'EMAIL:${_otherSelf.toLowerCase()}')
            .toSet();
        expect(
          external(_writableParticipants),
          external(_alternateParticipants),
        );
      },
    );

    test('qualified provenance resolves exactly one physical source', () {
      final decision = _resolve(newMessage);
      expect(decision.isSingleTarget, isTrue);
      expect(decision.physicalTargetRowIds, [_writableRow]);
      expect(decision.reason, 'UNIQUE_CURRENT_PROVENANCE_WRITABLE_SOURCE');
    });

    test(
      'physical input order and UI render order do not alter execution target',
      () {
        final forward = _resolve(
          newMessage,
          evidence: _evidence(
            candidates: [_candidate(_writableRow), _candidate(_alternateRow)],
          ),
        );
        final reverse = _resolve(
          newMessage,
          evidence: _evidence(
            candidates: [_candidate(_alternateRow), _candidate(_writableRow)],
          ),
        );
        expect(forward.physicalTargetRowIds, reverse.physicalTargetRowIds);
        expect(forward.physicalTargetRowIds, [_writableRow]);
      },
    );

    test('highest ROWID is not selected', () {
      expect(_alternateRow, greaterThan(_writableRow));
      expect(_resolve(newMessage).physicalTargetRowIds, [_writableRow]);
    });

    test(
      'most recent message alone cannot select between equally eligible sources',
      () {
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
      },
    );

    test(
      'three-member read certificate does not grant write authority to two eligible sources',
      () {
        final third = _candidate(
          30,
          sourceGuid: 'source-c-guid',
          participants: _writableParticipants,
          successfulOutbounds: const [
            LogicalSuccessfulOutboundEvidence(
              messageGuid: 'source-c-outbound',
              messageRowId: 303,
              createdAtEpoch: 3000,
            ),
          ],
        );
        final candidates = [
          _candidate(_alternateRow),
          _candidate(_writableRow),
          third,
        ];
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
      },
    );

    test(
      'selected source requires successful provenance newer than stale alternative provenance',
      () {
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
                  LogicalSuccessfulOutboundEvidence(
                    messageGuid: 'a-old',
                    messageRowId: 1,
                    createdAtEpoch: 1000,
                  ),
                ],
              ),
              _candidate(
                _alternateRow,
                successfulOutbounds: const [
                  LogicalSuccessfulOutboundEvidence(
                    messageGuid: 'b-new',
                    messageRowId: 2,
                    createdAtEpoch: 2000,
                  ),
                ],
              ),
            ],
          ),
        );
        expect(
          contradicted.reason,
          'CURRENT_OUTBOUND_PROVENANCE_CONTRADICTION',
        );
      },
    );

    test('unattached attachment uses one proven writable source', () {
      const request = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
      );
      expect(_resolve(request).physicalTargetRowIds, [_writableRow]);
    });

    test(
      'attachment retry remains pinned to its certified persisted physical source',
      () {
        const retry = LogicalMutationRequest(
          mutationClass: LogicalMutationClass.attachment,
          persistedExecutionSourceChatRowId: _alternateRow,
          persistedExecutionSourceChatGuid: 'source-b-guid',
          isRetry: true,
        );
        expect(_resolve(retry).physicalTargetRowIds, [_alternateRow]);
        expect(
          _resolve(retry).reason,
          'CERTIFIED_PERSISTED_ATTACHMENT_RETRY_ROUTE',
        );
      },
    );

    test(
      'attachment route hint cannot select a source outside an explicit retry',
      () {
        const initial = LogicalMutationRequest(
          mutationClass: LogicalMutationClass.attachment,
          persistedExecutionSourceChatRowId: _alternateRow,
          persistedExecutionSourceChatGuid: 'source-b-guid',
        );
        expect(_resolve(initial).reason, 'UNTRUSTED_ATTACHMENT_EXECUTION_HINT');
      },
    );

    test('wrong-source persisted attachment route fails closed', () {
      const retry = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.attachment,
        persistedExecutionSourceChatRowId: _alternateRow,
        persistedExecutionSourceChatGuid: 'source-a-guid',
        isRetry: true,
      );
      expect(
        _resolve(retry).reason,
        'PERSISTED_ATTACHMENT_ROUTE_CONTRADICTION',
      );
    });
  });

  group('fail-closed current source qualification', () {
    const request = LogicalMutationRequest(
      mutationClass: LogicalMutationClass.newMessage,
    );

    test('missing or mismatched equivalence certificate blocks mutation', () {
      expect(
        _resolve(request, evidence: _evidence(certificateId: null)).reason,
        'MISSING_EQUIVALENCE_CERTIFICATE',
      );
      expect(
        _resolve(
          request,
          evidence: _evidence(certificateId: 'unbound-certificate'),
        ).reason,
        'EQUIVALENCE_CERTIFICATE_BINDING_MISMATCH',
      );
      expect(
        _resolve(
          request,
          evidence: _evidence(logicalId: 'future-apparent-duplicate'),
        ).state,
        LogicalRouteState.routeNotProven,
      );
    });

    test(
      'zero, missing, extra, or duplicate candidates remain unqualified',
      () {
        final cases = <List<LogicalRouteCandidateEvidence>>[
          const [],
          [_candidate(_writableRow)],
          [_candidate(_writableRow), _candidate(_alternateRow), _candidate(30)],
          [_candidate(_writableRow), _candidate(_writableRow)],
        ];
        for (final candidates in cases) {
          expect(
            _resolve(
              request,
              evidence: _evidence(candidates: candidates),
            ).state,
            LogicalRouteState.routeNotProven,
          );
        }
      },
    );

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

    test(
      'account snapshot instability and active sender contradiction block mutation',
      () {
        expect(
          _resolve(
            request,
            evidence: _evidence(accountAfter: 'changed-account'),
          ).reason,
          'CURRENT_ACCOUNT_IDENTITY_UNSTABLE',
        );
        expect(
          _resolve(
            request,
            evidence: _evidence(
              activeSelfAlias: const LogicalAddressEvidence(
                address: 'unknown@example.invalid',
              ),
            ),
          ).reason,
          'ACTIVE_SENDER_NOT_CURRENT_VETTED_ALIAS',
        );
      },
    );

    test(
      'stale sender route, missing backend, and transport contradiction block mutation',
      () {
        final stale = _resolve(
          request,
          evidence: _evidence(
            candidates: [
              _candidate(
                _writableRow,
                lastAddressed: const LogicalAddressEvidence(
                  address: 'stale@example.invalid',
                ),
              ),
              _candidate(_alternateRow),
            ],
          ),
        );
        expect(stale.reason, 'STALE_OR_CONFLICTING_CURRENT_ROUTE');
        expect(
          _resolve(request, evidence: _evidence(backend: '')).reason,
          'BACKEND_IDENTITY_MISSING',
        );
        expect(
          _resolve(
            request,
            evidence: _evidence(privateApiConnected: false),
          ).reason,
          'CURRENT_TRANSPORT_CONTEXT_UNPROVEN',
        );
      },
    );

    test(
      'incomplete history, wrong source binding, and opaque identity fail closed',
      () {
        expect(
          _resolve(
            request,
            evidence: _evidence(
              candidates: [
                _candidate(_writableRow, messageSnapshotComplete: false),
                _candidate(_alternateRow),
              ],
            ),
          ).reason,
          'CURRENT_MESSAGE_PROVENANCE_INCOMPLETE',
        );
        expect(
          _resolve(
            request,
            evidence: _evidence(
              certifiedSourceChatGuids: const {
                _writableRow: 'wrong',
                _alternateRow: 'source-b-guid',
              },
            ),
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
      },
    );

    test('typed address normalization is conservative and deterministic', () {
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(
            address: 'mailto:PERSON@Example.Invalid',
          ),
        ),
        'EMAIL:person@example.invalid',
      );
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(
            address: '(202) 555-0101',
            country: 'US',
          ),
        ),
        'PHONE:+12025550101',
      );
      expect(
        LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(
          const LogicalAddressEvidence(
            address: '+44 20 7946 0958',
            country: 'GB',
          ),
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
      const unsupported = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.unsupported,
      );
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
      expect(_resolve(reply, evidence: ambiguousWriters).physicalTargetRowIds, [
        _alternateRow,
      ]);
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

    test('missing target identity never guesses', () {
      const reply = LogicalMutationRequest(
        mutationClass: LogicalMutationClass.reply,
      );
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
      expect(_resolve(bothUnread).physicalTargetRowIds, [
        _writableRow,
        _alternateRow,
      ]);
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
      expect(
        _resolve(oneUnread, evidence: ambiguousWriters).physicalTargetRowIds,
        [_alternateRow],
      );
    });

    test(
      'already-read performs no mutation and foreign unread source fails',
      () {
        const alreadyRead = LogicalMutationRequest(
          mutationClass: LogicalMutationClass.markRead,
        );
        const foreign = LogicalMutationRequest(
          mutationClass: LogicalMutationClass.markRead,
          unreadSourceChatRowIds: {999},
        );
        expect(_resolve(alreadyRead).physicalTargetRowIds, isEmpty);
        expect(_resolve(foreign).reason, 'UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
      },
    );

    test(
      'one action is admitted once across rebuild, rerender, and double tap',
      () {
        final gate = LogicalExecutionAdmissionGate();
        expect(gate.admit('action-1'), isTrue);
        expect(gate.admit('action-1'), isFalse);
        expect(gate.admit('action-1'), isFalse);
        expect(gate.admit('action-2'), isTrue);
      },
    );

    test('explicit user retry has one separate bounded admission', () {
      final gate = LogicalExecutionAdmissionGate();
      expect(gate.admit('retry-id'), isTrue);
      expect(gate.admit('retry-id', explicitRetry: true), isTrue);
      expect(gate.admit('retry-id', explicitRetry: true), isFalse);
    });

    test('empty action identity is never admitted', () {
      expect(LogicalExecutionAdmissionGate().admit(''), isFalse);
    });
  });
}
