import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:bluebubbles/services/ui/chat/new_group_provider_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_new_group_provider.dart';

const _account = 'account-a';
const _sender = 'sender-a';

NewGroupRecipientEvidence _recipient(String id, String handle) {
  return NewGroupRecipientEvidence(
    selectionId: id,
    normalizedHandle: handle,
    isSelf: false,
    iMessageCapability: NewGroupRecipientCapability.available,
    smsMmsCapability: NewGroupRecipientCapability.available,
    resolutionRevision: 'resolution-$id-v1',
    observedAtEpochMilliseconds: 900,
    validUntilEpochMilliseconds: 5000,
  );
}

NewLogicalConversationIntent _intent({
  String operationId = 'operation-1',
  String text = 'First group message',
  NewGroupRequestedService service = NewGroupRequestedService.iMessage,
  List<NewGroupRecipientEvidence>? recipients,
  List<NewGroupAttachmentIntent> attachments = const <NewGroupAttachmentIntent>[],
}) {
  return NewLogicalConversationIntent(
    operationId: operationId,
    recipients:
        recipients ??
        <NewGroupRecipientEvidence>[_recipient('alice', '+15550000001'), _recipient('bob', 'bob@example.test')],
    requestedService: service,
    expectedAccountIdentity: _account,
    expectedSenderIdentity: _sender,
    draftText: text,
    attachments: attachments,
    contentRevision: 1,
    createdAtEpochMilliseconds: 800,
  );
}

({
  FakeNewGroupClock clock,
  FakeNewGroupProvider provider,
  FakeNewGroupOperationStore store,
  NewGroupProviderCoordinator coordinator,
})
_fixture({Set<FakeNewGroupInjection>? injections}) {
  final clock = FakeNewGroupClock(1000);
  final provider = FakeNewGroupProvider(clock: clock, injections: injections);
  final store = FakeNewGroupOperationStore();
  final coordinator = NewGroupProviderCoordinator(provider: provider, store: store, now: clock.call);
  return (clock: clock, provider: provider, store: store, coordinator: coordinator);
}

void main() {
  group('provider capability and UI boundary', () {
    test('attested stock route is classified unsafe without account, sender, or idempotency contract', () {
      const capability = NewGroupProviderCapability(
        serverVersion: '1.9.7',
        evidenceRevision: 'helper-685f',
        observedAtEpochMilliseconds: 900,
        validUntilEpochMilliseconds: 5000,
        privateApiEnabled: true,
        helperConnected: true,
        helperCreateActionAttested: true,
        iMessageGroupSupported: true,
        smsMmsGroupSupported: true,
        explicitAccountBinding: false,
        explicitSenderBinding: false,
        operationIdempotency: false,
        appleObservation: true,
        attachmentFirstSend: false,
      );

      expect(capability.capabilityState, NewGroupProviderCapabilityState.privateRouteAttestedUnsafeContract);
    });

    test('unresolved groups can never reach raw create endpoint in Build 100', () {
      final decision = NewGroupBuild100UiGate.evaluate(
        recipientCount: 2,
        requestedService: NewGroupRequestedService.iMessage,
        recipientCapabilities: const <NewGroupRecipientCapability>[
          NewGroupRecipientCapability.available,
          NewGroupRecipientCapability.available,
        ],
      );

      expect(decision.mayInvokeCreateEndpoint, isFalse);
      expect(decision.userMessage, contains('safe provider operation contract missing'));
    });

    test('recipient failure is reported without silent iMessage downgrade', () {
      final decision = NewGroupBuild100UiGate.evaluate(
        recipientCount: 2,
        requestedService: NewGroupRequestedService.iMessage,
        recipientCapabilities: const <NewGroupRecipientCapability>[
          NewGroupRecipientCapability.available,
          NewGroupRecipientCapability.unavailable,
        ],
      );

      expect(decision.mayInvokeCreateEndpoint, isFalse);
      expect(decision.userMessage, 'Recipient unavailable for iMessage');
    });
  });

  group('durable provider state machine', () {
    test('success persists every boundary and exactly one Apple binding', () async {
      final fixture = _fixture();
      final intent = _intent();

      final admitted = await fixture.coordinator.prepare(intent);
      expect(admitted.state, NewGroupProviderOperationState.admitted);
      expect(admitted.transitions.map((value) => value.state), <NewGroupProviderOperationState>[
        NewGroupProviderOperationState.draft,
        NewGroupProviderOperationState.validated,
        NewGroupProviderOperationState.admitted,
      ]);

      final result = await fixture.coordinator.execute(intent.operationId);

      expect(result.state, NewGroupProviderOperationState.terminalSuccess);
      expect(result.dispatchInvocationCount, 1);
      expect(result.appleResult?.chatRowId, 101);
      expect(result.appleResult?.messageRowId, 202);
      expect(result.providerMessageIdentity, result.appleResult?.messageGuid);
      expect(fixture.provider.lastExecutionEnvelope?.normalizedRecipients, intent.normalizedRecipientSet);
      expect(fixture.provider.lastExecutionEnvelope?.draftText, intent.draftText);
      expect(
        result.transitions.where((value) => value.state == NewGroupProviderOperationState.appleResultObserved),
        hasLength(1),
      );
      expect(fixture.provider.executeInvocations, 1);
      expect(fixture.provider.physicalExecutions, 1);
    });

    test('duplicate provider callbacks produce one durable Apple binding', () async {
      final fixture = _fixture(injections: <FakeNewGroupInjection>{FakeNewGroupInjection.duplicateCallback});
      final intent = _intent();
      await fixture.coordinator.prepare(intent);

      final result = await fixture.coordinator.execute(intent.operationId);

      expect(result.state, NewGroupProviderOperationState.terminalSuccess);
      expect(fixture.provider.syntheticCallbackDeliveries, 2);
      expect(
        result.transitions.where((value) => value.state == NewGroupProviderOperationState.appleResultObserved),
        hasLength(1),
      );
      expect(fixture.provider.executeInvocations, 1);
      expect(fixture.provider.physicalExecutions, 1);
    });

    test('property: every operation identity dispatches at most once across repeated calls', () async {
      final fixture = _fixture();
      const operationCount = 32;

      for (var index = 0; index < operationCount; index += 1) {
        final intent = _intent(operationId: 'property-operation-$index', text: 'Property first message $index');
        final admissions = await Future.wait(<Future<NewGroupDurableOperation>>[
          fixture.coordinator.prepare(intent),
          fixture.coordinator.prepare(intent),
        ]);
        expect(admissions.every((value) => value.state == NewGroupProviderOperationState.admitted), isTrue);

        final executions = await Future.wait(<Future<NewGroupDurableOperation>>[
          fixture.coordinator.execute(intent.operationId),
          fixture.coordinator.execute(intent.operationId),
        ]);
        expect(executions.every((value) => value.state == NewGroupProviderOperationState.terminalSuccess), isTrue);
      }

      expect(fixture.provider.executeInvocations, operationCount);
      expect(fixture.provider.physicalExecutions, operationCount);
    });

    test('duplicated UI taps and reconnect still admit and dispatch once', () async {
      final fixture = _fixture(
        injections: <FakeNewGroupInjection>{FakeNewGroupInjection.duplicatedUiTap, FakeNewGroupInjection.reconnect},
      );
      final intent = _intent();

      final admissions = await Future.wait(<Future<NewGroupDurableOperation>>[
        fixture.coordinator.prepare(intent),
        fixture.coordinator.prepare(intent),
      ]);
      expect(admissions.map((value) => value.intent.operationId).toSet(), <String>{intent.operationId});

      final results = await Future.wait(<Future<NewGroupDurableOperation>>[
        fixture.coordinator.execute(intent.operationId),
        fixture.coordinator.execute(intent.operationId),
      ]);
      expect(results.every((value) => value.state == NewGroupProviderOperationState.terminalSuccess), isTrue);
      expect(fixture.provider.executeInvocations, 1);
      expect(fixture.provider.physicalExecutions, 1);
    });

    test('provider revision change before execution performs zero dispatches', () async {
      final fixture = _fixture(injections: <FakeNewGroupInjection>{FakeNewGroupInjection.providerRevisionChange});
      final intent = _intent();
      expect((await fixture.coordinator.prepare(intent)).state, NewGroupProviderOperationState.admitted);

      final result = await fixture.coordinator.execute(intent.operationId);

      expect(result.state, NewGroupProviderOperationState.preExecutionRejected);
      expect(result.reasonCode, 'PROVIDER_AUTHORITY_CHANGED_BEFORE_EXECUTION');
      expect(fixture.provider.executeInvocations, 0);
    });

    test('recipient account sender or service drift before execution performs zero dispatches', () async {
      for (final injection in <FakeNewGroupInjection>[
        FakeNewGroupInjection.recipientChangeBeforeExecution,
        FakeNewGroupInjection.accountChangeBeforeExecution,
        FakeNewGroupInjection.senderChangeBeforeExecution,
        FakeNewGroupInjection.serviceChangeBeforeExecution,
      ]) {
        final fixture = _fixture(injections: <FakeNewGroupInjection>{injection});
        final intent = _intent(operationId: 'operation-${injection.name}');
        expect((await fixture.coordinator.prepare(intent)).state, NewGroupProviderOperationState.admitted);

        final result = await fixture.coordinator.execute(intent.operationId);

        expect(result.state, NewGroupProviderOperationState.preExecutionRejected);
        expect(result.reasonCode, 'PROVIDER_AUTHORITY_CHANGED_BEFORE_EXECUTION');
        expect(fixture.provider.executeInvocations, 0);
        expect(fixture.provider.physicalExecutions, 0);
      }
    });

    test('recipient omission or addition is rejected before admission', () async {
      for (final injection in <FakeNewGroupInjection>[
        FakeNewGroupInjection.missingRecipient,
        FakeNewGroupInjection.extraRecipient,
      ]) {
        final fixture = _fixture(injections: <FakeNewGroupInjection>{injection});
        final result = await fixture.coordinator.prepare(_intent(operationId: 'operation-${injection.name}'));
        expect(result.state, NewGroupProviderOperationState.preExecutionRejected);
        expect(result.reasonCode, 'RECIPIENT_RESOLUTION_CHANGED_HUMAN_INTENT');
        expect(fixture.provider.executeInvocations, 0);
      }
    });

    test('account or sender mismatch is rejected before execution', () async {
      for (final injection in <FakeNewGroupInjection>[
        FakeNewGroupInjection.wrongAccount,
        FakeNewGroupInjection.wrongSender,
      ]) {
        final fixture = _fixture(injections: <FakeNewGroupInjection>{injection});
        final result = await fixture.coordinator.prepare(_intent(operationId: 'operation-${injection.name}'));
        expect(result.state, NewGroupProviderOperationState.preExecutionRejected);
        expect(fixture.provider.executeInvocations, 0);
      }
    });

    test('existing historical or multiple exact groups require selection', () async {
      for (final injection in <FakeNewGroupInjection>[
        FakeNewGroupInjection.existingHistoricalExactGroup,
        FakeNewGroupInjection.duplicatePhysicalGroup,
      ]) {
        final fixture = _fixture(injections: <FakeNewGroupInjection>{injection});
        final result = await fixture.coordinator.prepare(_intent(operationId: 'operation-${injection.name}'));
        expect(result.state, NewGroupProviderOperationState.preExecutionRejected);
        expect(result.reasonCode, contains('EXISTINGGROUPREQUIRESSELECTION'));
        expect(fixture.provider.executeInvocations, 0);
      }
    });

    test('provider rejection or timeout before execution invokes no first send', () async {
      for (final injection in <FakeNewGroupInjection>[
        FakeNewGroupInjection.helperPreExecutionFailure,
        FakeNewGroupInjection.helperTimeoutBeforeExecution,
      ]) {
        final fixture = _fixture(injections: <FakeNewGroupInjection>{injection});
        final intent = _intent(operationId: 'operation-${injection.name}');
        await fixture.coordinator.prepare(intent);
        final result = await fixture.coordinator.execute(intent.operationId);
        expect(result.state, NewGroupProviderOperationState.preExecutionRejected);
        expect(fixture.provider.executeInvocations, 0);
        expect(fixture.provider.physicalExecutions, 0);
      }
    });

    test('timeout after execution is ambiguous, never retries, and reconciles exactly', () async {
      final fixture = _fixture(injections: <FakeNewGroupInjection>{FakeNewGroupInjection.helperTimeoutAfterExecution});
      final intent = _intent();
      await fixture.coordinator.prepare(intent);

      final ambiguous = await fixture.coordinator.execute(intent.operationId);
      expect(ambiguous.state, NewGroupProviderOperationState.outcomeAmbiguous);
      expect(ambiguous.reasonCode, 'NEW_GROUP_OUTCOME_AMBIGUOUS');
      expect(fixture.provider.physicalExecutions, 1);

      final replay = await fixture.coordinator.execute(intent.operationId);
      expect(replay.state, NewGroupProviderOperationState.outcomeAmbiguous);
      expect(fixture.provider.executeInvocations, 1);

      final reconciled = await fixture.coordinator.reconcile(intent.operationId);
      expect(reconciled.state, NewGroupProviderOperationState.terminalSuccess);
      expect(reconciled.dispatchInvocationCount, 1);
      expect(fixture.provider.executeInvocations, 1);
    });

    test('delayed Apple observation reconciles without dispatch replay', () async {
      final fixture = _fixture(injections: <FakeNewGroupInjection>{FakeNewGroupInjection.delayedAppleObservation});
      final intent = _intent();
      await fixture.coordinator.prepare(intent);
      expect(
        (await fixture.coordinator.execute(intent.operationId)).state,
        NewGroupProviderOperationState.outcomeAmbiguous,
      );

      final first = await fixture.coordinator.reconcile(intent.operationId);
      final second = await fixture.coordinator.reconcile(intent.operationId);

      expect(first.state, NewGroupProviderOperationState.terminalSuccess);
      expect(second.state, NewGroupProviderOperationState.terminalSuccess);
      expect(fixture.provider.reconciliationInvocations, 1);
      expect(fixture.provider.executeInvocations, 1);
    });

    test('wrong Apple account sender message recipients or service never binds', () async {
      for (final injection in <FakeNewGroupInjection>[
        FakeNewGroupInjection.wrongObservationAccount,
        FakeNewGroupInjection.wrongObservationSender,
        FakeNewGroupInjection.wrongObservationMessageIdentity,
        FakeNewGroupInjection.missingObservationRecipient,
        FakeNewGroupInjection.extraObservationRecipient,
        FakeNewGroupInjection.serviceDowngrade,
      ]) {
        final fixture = _fixture(injections: <FakeNewGroupInjection>{injection});
        final intent = _intent(operationId: 'operation-${injection.name}');
        await fixture.coordinator.prepare(intent);
        final result = await fixture.coordinator.execute(intent.operationId);
        expect(result.state, NewGroupProviderOperationState.outcomeAmbiguous);
        expect(result.appleResult, isNull);
        expect(fixture.provider.executeInvocations, 1);
      }
    });

    test('same operation identity cannot be rebound to stale draft or service', () async {
      final fixture = _fixture();
      await fixture.coordinator.prepare(_intent());

      expect(() => fixture.coordinator.prepare(_intent(text: 'changed text')), throwsA(isA<StateError>()));
      expect(
        () => fixture.coordinator.prepare(_intent(service: NewGroupRequestedService.smsMms)),
        throwsA(isA<StateError>()),
      );
      expect(fixture.provider.executeInvocations, 0);
    });

    test('attachment intent is bound into identity and carried by the execution envelope', () async {
      final without = _intent();
      final withAttachment = _intent(
        attachments: const <NewGroupAttachmentIntent>[
          NewGroupAttachmentIntent(
            intentId: 'attachment-1',
            name: 'photo.jpg',
            size: 100,
            contentFingerprint: 'sha256-photo',
          ),
        ],
      );
      expect(without.operationBindingFingerprint, isNot(withAttachment.operationBindingFingerprint));

      final fixture = _fixture();
      await fixture.coordinator.prepare(withAttachment);
      final result = await fixture.coordinator.execute(withAttachment.operationId);
      final envelope = fixture.provider.lastExecutionEnvelope!;

      expect(result.state, NewGroupProviderOperationState.terminalSuccess);
      expect(envelope.normalizedRecipients, withAttachment.normalizedRecipientSet);
      expect(envelope.draftText, withAttachment.draftText);
      expect(envelope.draftContentFingerprint, withAttachment.draftContentFingerprint);
      expect(envelope.attachments.single.contentFingerprint, 'sha256-photo');
    });
  });

  group('crash durability and failure injection', () {
    test('restart resumes safely after draft validated or admitted persistence', () async {
      for (final boundary in <int>[1, 2, 3]) {
        final fixture = _fixture();
        final intent = _intent(operationId: 'operation-save-$boundary');
        fixture.store.throwAfterSaveNumber = boundary;
        await expectLater(fixture.coordinator.prepare(intent), throwsStateError);
        fixture.store.clearFailure();
        final restarted = NewGroupProviderCoordinator(
          provider: fixture.provider,
          store: fixture.store,
          now: fixture.clock.call,
        );
        final recovered = await restarted.prepare(intent);
        expect(recovered.state, NewGroupProviderOperationState.admitted);
        expect(recovered.operationBindingFingerprint, intent.operationBindingFingerprint);
        expect(fixture.provider.executeInvocations, 0);
      }
    });
    test('death at local or provider reservation rejects without dispatch', () async {
      for (final boundary in <int>[4, 5]) {
        final fixture = _fixture();
        final intent = _intent(operationId: 'operation-reservation-$boundary');
        await fixture.coordinator.prepare(intent);
        fixture.store.throwAfterSaveNumber = boundary;

        await expectLater(fixture.coordinator.execute(intent.operationId), throwsStateError);
        expect(fixture.provider.executeInvocations, 0);
        fixture.store.clearFailure();
        final restarted = NewGroupProviderCoordinator(
          provider: fixture.provider,
          store: fixture.store,
          now: fixture.clock.call,
        );
        final recovered = await restarted.recoverAfterRestart();
        expect(recovered.single.state, NewGroupProviderOperationState.preExecutionRejected);
        expect(
          (await restarted.execute(intent.operationId)).state,
          NewGroupProviderOperationState.preExecutionRejected,
        );
        expect(fixture.provider.executeInvocations, 0);
      }
    });

    test('death after durable execution-start marker becomes ambiguous without dispatch replay', () async {
      final fixture = _fixture();
      final intent = _intent();
      await fixture.coordinator.prepare(intent);
      fixture.store.throwAfterSaveNumber = 6;
      await expectLater(fixture.coordinator.execute(intent.operationId), throwsStateError);
      expect(fixture.provider.executeInvocations, 0);
      fixture.store.clearFailure();
      final restarted = NewGroupProviderCoordinator(
        provider: fixture.provider,
        store: fixture.store,
        now: fixture.clock.call,
      );
      final recovered = await restarted.recoverAfterRestart();
      expect(recovered.single.state, NewGroupProviderOperationState.outcomeAmbiguous);
      expect((await restarted.execute(intent.operationId)).state, NewGroupProviderOperationState.outcomeAmbiguous);
      expect(fixture.provider.executeInvocations, 0);
    });

    test('death after durable provider receipt is ambiguous and reconciles without replay', () async {
      final fixture = _fixture();
      final intent = _intent();
      await fixture.coordinator.prepare(intent);
      fixture.store.throwAfterSaveNumber = 7;
      await expectLater(fixture.coordinator.execute(intent.operationId), throwsStateError);
      expect(fixture.provider.executeInvocations, 1);
      expect(fixture.provider.physicalExecutions, 1);
      fixture.store.clearFailure();
      final restarted = NewGroupProviderCoordinator(
        provider: fixture.provider,
        store: fixture.store,
        now: fixture.clock.call,
      );
      final recovered = await restarted.recoverAfterRestart();
      expect(recovered.single.state, NewGroupProviderOperationState.outcomeAmbiguous);
      expect((await restarted.execute(intent.operationId)).state, NewGroupProviderOperationState.outcomeAmbiguous);
      expect(fixture.provider.executeInvocations, 1);

      final reconciled = await restarted.reconcile(intent.operationId);
      expect(reconciled.state, NewGroupProviderOperationState.terminalSuccess);
      expect(fixture.provider.executeInvocations, 1);
    });

    test('death after Apple result persistence recovers terminal success without replay', () async {
      final fixture = _fixture();
      final intent = _intent();
      await fixture.coordinator.prepare(intent);
      fixture.store.throwAfterSaveNumber = 8;
      await expectLater(fixture.coordinator.execute(intent.operationId), throwsStateError);
      expect(fixture.provider.executeInvocations, 1);
      fixture.store.clearFailure();
      final restarted = NewGroupProviderCoordinator(
        provider: fixture.provider,
        store: fixture.store,
        now: fixture.clock.call,
      );
      final recovered = await restarted.recoverAfterRestart();
      expect(recovered.single.state, NewGroupProviderOperationState.terminalSuccess);
      expect(recovered.single.appleResult, isNotNull);
      expect(fixture.provider.executeInvocations, 1);
    });

    test('death after durable terminal success remains terminal without replay', () async {
      final fixture = _fixture();
      final intent = _intent();
      await fixture.coordinator.prepare(intent);
      fixture.store.throwAfterSaveNumber = 9;
      await expectLater(fixture.coordinator.execute(intent.operationId), throwsStateError);
      expect(fixture.provider.executeInvocations, 1);
      fixture.store.clearFailure();
      final restarted = NewGroupProviderCoordinator(
        provider: fixture.provider,
        store: fixture.store,
        now: fixture.clock.call,
      );
      final recovered = await restarted.recoverAfterRestart();
      expect(recovered.single.state, NewGroupProviderOperationState.terminalSuccess);
      expect((await restarted.execute(intent.operationId)).state, NewGroupProviderOperationState.terminalSuccess);
      expect(fixture.provider.executeInvocations, 1);
    });

    test('journal round trip has no invented Apple identity before observation', () async {
      final fixture = _fixture();
      final intent = _intent();
      await fixture.coordinator.prepare(intent);
      final restored = await fixture.store.load();
      final operation = restored.operationFor(intent.operationId)!;
      expect(operation.state, NewGroupProviderOperationState.admitted);
      expect(operation.appleResult, isNull);
      expect(operation.providerRequestId, isNull);
    });
  });
}
