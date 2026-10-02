import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:flutter_test/flutter_test.dart';

const _now = 1000;
const _account = 'account-proof-a';
const _sender = 'sender-proof-a';

NewGroupRecipientEvidence _recipient(
  String id,
  String handle, {
  bool isSelf = false,
  NewGroupRecipientCapability iMessage = NewGroupRecipientCapability.available,
  NewGroupRecipientCapability smsMms = NewGroupRecipientCapability.available,
  int validUntil = 2000,
}) {
  return NewGroupRecipientEvidence(
    selectionId: id,
    normalizedHandle: handle,
    isSelf: isSelf,
    iMessageCapability: iMessage,
    smsMmsCapability: smsMms,
    resolutionRevision: 'resolution-$id',
    observedAtEpochMilliseconds: 900,
    validUntilEpochMilliseconds: validUntil,
  );
}

NewGroupAttachmentIntent _attachment() {
  return const NewGroupAttachmentIntent(
    intentId: 'attachment-1',
    name: 'photo.jpg',
    size: 4096,
    contentFingerprint: 'sha256-photo',
  );
}

NewLogicalConversationIntent _intent({
  String operationId = 'operation-1',
  List<NewGroupRecipientEvidence>? recipients,
  NewGroupRequestedService service = NewGroupRequestedService.iMessage,
  String account = _account,
  String sender = _sender,
  String text = 'First group message',
  List<NewGroupAttachmentIntent> attachments = const <NewGroupAttachmentIntent>[],
  int contentRevision = 1,
}) {
  return NewLogicalConversationIntent(
    operationId: operationId,
    recipients:
        recipients ??
        <NewGroupRecipientEvidence>[_recipient('alice', '+15550000001'), _recipient('bob', 'bob@example.test')],
    requestedService: service,
    expectedAccountIdentity: account,
    expectedSenderIdentity: sender,
    draftText: text,
    attachments: attachments,
    contentRevision: contentRevision,
    createdAtEpochMilliseconds: 800,
  );
}

NewGroupProviderCapability _provider({
  bool privateApi = true,
  bool helper = true,
  bool helperAction = true,
  bool iMessage = true,
  bool smsMms = true,
  bool accountBinding = true,
  bool senderBinding = true,
  bool idempotency = true,
  bool observation = true,
  bool attachments = true,
  String evidenceRevision = 'provider-v1',
}) {
  return NewGroupProviderCapability(
    serverVersion: 'test-safe-provider',
    evidenceRevision: evidenceRevision,
    observedAtEpochMilliseconds: 900,
    validUntilEpochMilliseconds: 2000,
    privateApiEnabled: privateApi,
    helperConnected: helper,
    helperCreateActionAttested: helperAction,
    iMessageGroupSupported: iMessage,
    smsMmsGroupSupported: smsMms,
    explicitAccountBinding: accountBinding,
    explicitSenderBinding: senderBinding,
    operationIdempotency: idempotency,
    appleObservation: observation,
    attachmentFirstSend: attachments,
  );
}

NewGroupAccountProof _accountProof({String account = _account, String sender = _sender}) {
  return NewGroupAccountProof(
    accountIdentity: account,
    senderIdentity: sender,
    evidenceRevision: 'account-v1',
    observedAtEpochMilliseconds: 900,
    validUntilEpochMilliseconds: 2000,
  );
}

NewGroupPreflightResult _preflight(
  NewLogicalConversationIntent intent, {
  NewGroupProviderCapability? provider,
  NewGroupAccountProof? accountProof,
  Iterable<ExistingPhysicalGroupEvidence> existingGroups = const <ExistingPhysicalGroupEvidence>[],
}) {
  return NewGroupPreflight.evaluate(
    intent: intent,
    provider: provider ?? _provider(),
    accountProof: accountProof ?? _accountProof(),
    existingGroups: existingGroups,
    nowEpochMilliseconds: _now,
  );
}

ExistingPhysicalGroupEvidence _existing(
  String id, {
  List<String> recipients = const <String>['+15550000001', 'bob@example.test'],
  NewGroupRequestedService service = NewGroupRequestedService.iMessage,
  String account = _account,
  bool historical = false,
}) {
  return ExistingPhysicalGroupEvidence(
    physicalIdentity: id,
    normalizedRecipients: recipients,
    service: service,
    accountIdentity: account,
    isHistorical: historical,
  );
}

NewGroupAppleObservation _observation(
  NewLogicalConversationIntent intent, {
  List<String>? recipients,
  int firstMessageCount = 1,
  String account = _account,
  String sender = _sender,
}) {
  return NewGroupAppleObservation(
    chatGuid: 'iMessage;+;apple-created-guid',
    chatRowId: 42,
    firstMessageGuid: 'first-message-guid',
    normalizedRecipients: recipients ?? intent.normalizedRecipientSet,
    service: intent.requestedService,
    accountIdentity: account,
    senderIdentity: sender,
    draftContentFingerprint: intent.draftContentFingerprint,
    matchingFirstMessageCount: firstMessageCount,
    isFromMe: true,
    isTerminallySent: true,
  );
}

({NewGroupOperationLedger ledger, NewGroupProviderCapability provider}) _admitted(NewLogicalConversationIntent intent) {
  final provider = _provider();
  final preflight = _preflight(intent, provider: provider);
  expect(preflight.state, NewGroupPreflightState.ready);
  final ledger = NewGroupOperationLedger.empty();
  final result = ledger.admit(intent: intent, provider: provider, preflight: preflight, nowEpochMilliseconds: _now);
  expect(result.created, isTrue);
  return (ledger: ledger, provider: provider);
}

void main() {
  group('new group preflight', () {
    test('two exact iMessage recipients are ready only under a safe provider contract', () {
      final result = _preflight(_intent());

      expect(result.state, NewGroupPreflightState.ready);
      expect(result.userMessage, 'Group iMessage ready');
    });

    test('larger exact recipient set is preserved and sorted without omission', () {
      final intent = _intent(
        recipients: <NewGroupRecipientEvidence>[
          _recipient('charlie', '+15550000003'),
          _recipient('alice', '+15550000001'),
          _recipient('bob', '+15550000002'),
          _recipient('dana', 'dana@example.test'),
        ],
      );

      expect(_preflight(intent).state, NewGroupPreflightState.ready);
      expect(intent.normalizedRecipientSet, <String>[
        '+15550000001',
        '+15550000002',
        '+15550000003',
        'dana@example.test',
      ]);
    });

    test('duplicate provider-normalized recipients block instead of being deduplicated', () {
      final intent = _intent(
        recipients: <NewGroupRecipientEvidence>[
          _recipient('alice-contact', '+15550000001'),
          _recipient('alice-manual', '+15550000001'),
        ],
      );

      final result = _preflight(intent);

      expect(result.reason, NewGroupFailureReason.duplicateRecipient);
      expect(intent.recipients, hasLength(2));
    });

    test('accidental self inclusion blocks', () {
      final intent = _intent(
        recipients: <NewGroupRecipientEvidence>[
          _recipient('alice', '+15550000001'),
          _recipient('self', '+15550000999', isSelf: true),
        ],
      );

      expect(_preflight(intent).reason, NewGroupFailureReason.selfRecipient);
    });

    test('mixed capability never downgrades requested iMessage to SMS/MMS', () {
      final intent = _intent(
        recipients: <NewGroupRecipientEvidence>[
          _recipient('alice', '+15550000001'),
          _recipient(
            'sms-only',
            '+15550000002',
            iMessage: NewGroupRecipientCapability.unavailable,
            smsMms: NewGroupRecipientCapability.available,
          ),
        ],
      );

      final result = _preflight(intent);

      expect(result.reason, NewGroupFailureReason.recipientUnavailable);
      expect(result.userMessage, 'Recipient unavailable for iMessage');
      expect(intent.requestedService, NewGroupRequestedService.iMessage);
    });

    test('unknown participant capability blocks rather than guessing', () {
      final intent = _intent(
        recipients: <NewGroupRecipientEvidence>[
          _recipient('alice', '+15550000001'),
          _recipient('unknown', '+15550000002', iMessage: NewGroupRecipientCapability.unknown),
        ],
      );

      expect(_preflight(intent).reason, NewGroupFailureReason.recipientCapabilityUnknown);
    });

    test('stale recipient resolution blocks', () {
      final intent = _intent(
        recipients: <NewGroupRecipientEvidence>[
          _recipient('alice', '+15550000001'),
          _recipient('stale', '+15550000002', validUntil: 999),
        ],
      );

      expect(_preflight(intent).reason, NewGroupFailureReason.staleRecipientResolution);
    });

    test('account mismatch blocks before admission', () {
      final result = _preflight(_intent(), accountProof: _accountProof(account: 'different-account'));

      expect(result.reason, NewGroupFailureReason.accountMismatch);
    });

    test('sender mismatch blocks before admission', () {
      final result = _preflight(_intent(), accountProof: _accountProof(sender: 'different-sender'));

      expect(result.reason, NewGroupFailureReason.senderMismatch);
    });

    test('private API unavailable reports bounded capability state', () {
      final result = _preflight(_intent(), provider: _provider(privateApi: false));

      expect(result.reason, NewGroupFailureReason.privateApiUnavailable);
      expect(result.userMessage, 'Group creation unavailable — Private API capability missing');
    });

    test('helper unavailable reports bounded capability state', () {
      final result = _preflight(_intent(), provider: _provider(helper: false));

      expect(result.reason, NewGroupFailureReason.helperUnavailable);
      expect(result.userMessage, 'Group creation unavailable — helper capability missing');
    });

    test('upstream-style helper contract is technical but not safely admissible', () {
      final result = _preflight(
        _intent(),
        provider: _provider(accountBinding: false, senderBinding: false, idempotency: false),
      );

      expect(result.reason, NewGroupFailureReason.accountBindingUnsupported);
      expect(result.state, NewGroupPreflightState.blocked);
    });

    test('requested SMS/MMS is evaluated independently and never promoted to iMessage', () {
      final intent = _intent(
        service: NewGroupRequestedService.smsMms,
        recipients: <NewGroupRecipientEvidence>[
          _recipient('alice', '+15550000001'),
          _recipient(
            'no-sms',
            '+15550000002',
            iMessage: NewGroupRecipientCapability.available,
            smsMms: NewGroupRecipientCapability.unavailable,
          ),
        ],
      );

      final result = _preflight(intent);

      expect(result.reason, NewGroupFailureReason.recipientUnavailable);
      expect(intent.requestedService, NewGroupRequestedService.smsMms);
    });

    test('attachment intent is preserved and blocks when first-send attachments are unsupported', () {
      final intent = _intent(attachments: <NewGroupAttachmentIntent>[_attachment()]);
      final result = _preflight(intent, provider: _provider(attachments: false));

      expect(result.reason, NewGroupFailureReason.attachmentFirstSendUnsupported);
      expect(intent.attachments.single.intentId, 'attachment-1');
      expect(intent.draftContentFingerprint, isNotEmpty);
    });
  });

  group('existing physical group policy', () {
    test('no exact existing group allows creation', () {
      final result = _preflight(
        _intent(),
        existingGroups: <ExistingPhysicalGroupEvidence>[
          _existing('unrelated', recipients: const <String>['+15550000001', '+15550009999']),
        ],
      );

      expect(result.state, NewGroupPreflightState.ready);
    });

    test('one current exact group requires explicit selection', () {
      final result = _preflight(_intent(), existingGroups: <ExistingPhysicalGroupEvidence>[_existing('current')]);

      expect(result.state, NewGroupPreflightState.existingSelectionRequired);
      expect(result.userMessage, 'Existing matching group requires selection');
    });

    test('one historical exact-set group requires explicit selection', () {
      final intent = _intent();
      final evidence = _existing('historical', historical: true);
      final decision = NewGroupExistingDecision.evaluate(intent, <ExistingPhysicalGroupEvidence>[evidence]);

      expect(decision.state, NewGroupExistingMatchState.exactHistorical);
      expect(
        _preflight(intent, existingGroups: <ExistingPhysicalGroupEvidence>[evidence]).state,
        NewGroupPreflightState.existingSelectionRequired,
      );
    });

    test('multiple exact physical groups remain ambiguous and are never first-match reused', () {
      final intent = _intent();
      final evidence = <ExistingPhysicalGroupEvidence>[_existing('current'), _existing('historical', historical: true)];
      final decision = NewGroupExistingDecision.evaluate(intent, evidence);

      expect(decision.state, NewGroupExistingMatchState.multipleExact);
      expect(decision.matchingPhysicalIdentities, <String>['current', 'historical']);
      expect(_preflight(intent, existingGroups: evidence).state, NewGroupPreflightState.existingSelectionRequired);
    });

    test('same recipients with another service or account are not an exact match', () {
      final intent = _intent();
      final decision = NewGroupExistingDecision.evaluate(intent, <ExistingPhysicalGroupEvidence>[
        _existing('sms', service: NewGroupRequestedService.smsMms),
        _existing('other-account', account: 'other-account'),
      ]);

      expect(decision.state, NewGroupExistingMatchState.none);
    });
  });

  group('durable admission and failure injection', () {
    test('intent and ledger survive JSON round-trip without changing identity', () {
      final intent = _intent(attachments: <NewGroupAttachmentIntent>[_attachment()]);
      final decodedIntent = NewLogicalConversationIntent.fromJson(
        (jsonDecode(jsonEncode(intent.toJson())) as Map).cast<String, dynamic>(),
      );
      final admitted = _admitted(intent);
      final decodedLedger = NewGroupOperationLedger.fromJson(
        (jsonDecode(jsonEncode(admitted.ledger.toJson())) as Map).cast<String, dynamic>(),
      );

      expect(decodedIntent.intentFingerprint, intent.intentFingerprint);
      expect(decodedLedger.recordFor(intent.operationId)!.intentFingerprint, intent.intentFingerprint);
      expect(decodedLedger.recordFor(intent.operationId)!.appleChatGuid, isNull);
    });

    test('double tap admits once and grants no second execution', () {
      final intent = _intent();
      final provider = _provider();
      final preflight = _preflight(intent, provider: provider);
      final ledger = NewGroupOperationLedger.empty();

      final first = ledger.admit(intent: intent, provider: provider, preflight: preflight, nowEpochMilliseconds: 1000);
      final second = ledger.admit(intent: intent, provider: provider, preflight: preflight, nowEpochMilliseconds: 1001);
      final reservation = ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: provider.revision,
        currentPreflight: preflight,
        nowEpochMilliseconds: 1002,
      );
      final repeatedReservation = ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: provider.revision,
        currentPreflight: preflight,
        nowEpochMilliseconds: 1003,
      );

      expect(first.created, isTrue);
      expect(second.reason, NewGroupFailureReason.duplicateAdmission);
      expect(reservation.dispatchGranted, isTrue);
      expect(repeatedReservation.dispatchGranted, isFalse);
      expect(ledger.recordFor(intent.operationId)!.executionAttemptCount, 1);
    });

    test('stale draft with reused operation identity cannot dispatch', () {
      final original = _intent();
      final admitted = _admitted(original);
      final changed = _intent(text: 'Changed after admission', contentRevision: 2);

      final result = admitted.ledger.admit(
        intent: changed,
        provider: admitted.provider,
        preflight: _preflight(changed, provider: admitted.provider),
        nowEpochMilliseconds: 1001,
      );

      expect(result.reason, NewGroupFailureReason.staleIntent);
      expect(result.executionMayStart, isFalse);
      final reservation = admitted.ledger.reserveExecution(
        intent: changed,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: _preflight(changed, provider: admitted.provider),
        nowEpochMilliseconds: 1002,
      );
      expect(reservation.dispatchGranted, isFalse);
      expect(reservation.record.state, NewGroupOperationState.blockedBeforeExecution);
    });

    test('capability revision drift after admission prevents transport reservation', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      final driftedProvider = _provider(evidenceRevision: 'provider-v2');

      final reservation = admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: driftedProvider.revision,
        currentPreflight: _preflight(intent, provider: driftedProvider),
        nowEpochMilliseconds: 1001,
      );

      expect(reservation.dispatchGranted, isFalse);
      expect(admitted.ledger.recordFor(intent.operationId)!.state, NewGroupOperationState.blockedBeforeExecution);
      expect(admitted.ledger.recordFor(intent.operationId)!.reason, NewGroupFailureReason.admissionEvidenceChanged);
      expect(
        admitted.ledger
            .reserveExecution(
              intent: intent,
              currentProviderCapabilityRevision: admitted.provider.revision,
              currentPreflight: _preflight(intent, provider: admitted.provider),
              nowEpochMilliseconds: 1002,
            )
            .dispatchGranted,
        isFalse,
      );
    });

    test('new exact existing-group evidence after admission blocks terminally before transport', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      final changedPreflight = _preflight(
        intent,
        provider: admitted.provider,
        existingGroups: <ExistingPhysicalGroupEvidence>[_existing('appeared-after-admission')],
      );

      final reservation = admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: changedPreflight,
        nowEpochMilliseconds: 1001,
      );

      expect(changedPreflight.state, NewGroupPreflightState.existingSelectionRequired);
      expect(reservation.dispatchGranted, isFalse);
      expect(reservation.record.state, NewGroupOperationState.blockedBeforeExecution);
      expect(reservation.record.reason, NewGroupFailureReason.admissionEvidenceChanged);
    });

    test('timeout before execution proves no dispatch and blocks the operation', () {
      final intent = _intent();
      final admitted = _admitted(intent);

      expect(admitted.ledger.markTimeoutBeforeExecution(intent.operationId, 1001), isTrue);
      final record = admitted.ledger.recordFor(intent.operationId)!;

      expect(record.state, NewGroupOperationState.blockedBeforeExecution);
      expect(record.executionAttemptCount, 0);
      expect(record.reason, NewGroupFailureReason.timeoutBeforeExecution);
    });

    test('timeout after execution begins becomes NEW_GROUP_OUTCOME_AMBIGUOUS', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      expect(
        admitted.ledger
            .reserveExecution(
              intent: intent,
              currentProviderCapabilityRevision: admitted.provider.revision,
              currentPreflight: _preflight(intent, provider: admitted.provider),
              nowEpochMilliseconds: 1001,
            )
            .dispatchGranted,
        isTrue,
      );

      expect(admitted.ledger.markOutcomeAmbiguous(intent.operationId, 1002), isTrue);
      final record = admitted.ledger.recordFor(intent.operationId)!;

      expect(record.state, NewGroupOperationState.outcomeAmbiguous);
      expect(record.userMessage, 'Group creation outcome unknown — do not retry automatically');
      expect(
        admitted.ledger
            .reserveExecution(
              intent: intent,
              currentProviderCapabilityRevision: admitted.provider.revision,
              currentPreflight: _preflight(intent, provider: admitted.provider),
              nowEpochMilliseconds: 1003,
            )
            .dispatchGranted,
        isFalse,
      );
    });

    test('reconnect converts an interrupted execution to ambiguous and replay stays blocked', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: _preflight(intent, provider: admitted.provider),
        nowEpochMilliseconds: 1001,
      );
      final restored = NewGroupOperationLedger.fromJson(
        (jsonDecode(jsonEncode(admitted.ledger.toJson())) as Map).cast<String, dynamic>(),
      );

      expect(restored.recoverInterruptedExecutions(1002), 1);
      expect(restored.recordFor(intent.operationId)!.state, NewGroupOperationState.outcomeAmbiguous);
      expect(
        restored
            .reserveExecution(
              intent: intent,
              currentProviderCapabilityRevision: admitted.provider.revision,
              currentPreflight: _preflight(intent, provider: admitted.provider),
              nowEpochMilliseconds: 1003,
            )
            .dispatchGranted,
        isFalse,
      );
    });

    test('read-only reconciliation may resolve ambiguity without granting a replay', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: _preflight(intent, provider: admitted.provider),
        nowEpochMilliseconds: 1001,
      );
      expect(admitted.ledger.markOutcomeAmbiguous(intent.operationId, 1002), isTrue);

      expect(
        admitted.ledger.confirmAppleObservation(
          intent: intent,
          observation: _observation(intent),
          nowEpochMilliseconds: 1003,
        ),
        isTrue,
      );
      final record = admitted.ledger.recordFor(intent.operationId)!;

      expect(record.state, NewGroupOperationState.succeeded);
      expect(record.executionAttemptCount, 1);
    });

    test('exact Apple observation binds canonical chat only after one terminal first send', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      final before = admitted.ledger.recordFor(intent.operationId)!;
      expect(before.appleChatGuid, isNull);
      admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: _preflight(intent, provider: admitted.provider),
        nowEpochMilliseconds: 1001,
      );

      expect(
        admitted.ledger.confirmAppleObservation(
          intent: intent,
          observation: _observation(intent),
          nowEpochMilliseconds: 1002,
        ),
        isTrue,
      );
      final record = admitted.ledger.recordFor(intent.operationId)!;

      expect(record.state, NewGroupOperationState.succeeded);
      expect(record.executionAttemptCount, 1);
      expect(record.appleChatGuid, 'iMessage;+;apple-created-guid');
      expect(record.firstMessageGuid, 'first-message-guid');
    });

    test('two matching first messages fail exactly-once verification and become ambiguous', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: _preflight(intent, provider: admitted.provider),
        nowEpochMilliseconds: 1001,
      );

      expect(
        admitted.ledger.confirmAppleObservation(
          intent: intent,
          observation: _observation(intent, firstMessageCount: 2),
          nowEpochMilliseconds: 1002,
        ),
        isFalse,
      );
      final record = admitted.ledger.recordFor(intent.operationId)!;

      expect(record.state, NewGroupOperationState.outcomeAmbiguous);
      expect(record.reason, NewGroupFailureReason.duplicateFirstSend);
    });

    test('Apple observation with an omitted or added recipient never binds', () {
      final intent = _intent();
      final admitted = _admitted(intent);
      admitted.ledger.reserveExecution(
        intent: intent,
        currentProviderCapabilityRevision: admitted.provider.revision,
        currentPreflight: _preflight(intent, provider: admitted.provider),
        nowEpochMilliseconds: 1001,
      );

      expect(
        admitted.ledger.confirmAppleObservation(
          intent: intent,
          observation: _observation(intent, recipients: const <String>['+15550000001']),
          nowEpochMilliseconds: 1002,
        ),
        isFalse,
      );
      expect(admitted.ledger.recordFor(intent.operationId)!.reason, NewGroupFailureReason.observationMismatch);
    });
  });
}
