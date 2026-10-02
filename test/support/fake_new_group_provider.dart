import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:bluebubbles/services/ui/chat/new_group_provider_contract.dart';

enum FakeNewGroupInjection {
  helperSuccess,
  helperPreExecutionFailure,
  helperTimeoutBeforeExecution,
  helperTimeoutAfterExecution,
  duplicateCallback,
  delayedAppleObservation,
  wrongAccount,
  wrongSender,
  accountChangeBeforeExecution,
  senderChangeBeforeExecution,
  recipientChangeBeforeExecution,
  serviceChangeBeforeExecution,
  missingRecipient,
  extraRecipient,
  wrongObservationAccount,
  wrongObservationSender,
  wrongObservationMessageIdentity,
  missingObservationRecipient,
  extraObservationRecipient,
  serviceDowngrade,
  duplicatePhysicalGroup,
  existingHistoricalExactGroup,
  providerRevisionChange,
  processDeath,
  reconnect,
  duplicatedUiTap,
}

class FakeNewGroupClock {
  FakeNewGroupClock(this.value);
  int value;
  int call() => value;
  void advance([int delta = 1]) => value += delta;
}

class FakeNewGroupOperationStore implements NewGroupOperationStore {
  String? _json;
  int saveCount = 0;
  int? throwBeforeSaveNumber;
  int? throwAfterSaveNumber;

  @override
  Future<NewGroupOperationJournal> load() async {
    if (_json == null) return NewGroupOperationJournal.empty();
    return NewGroupOperationJournal.fromJson((jsonDecode(_json!) as Map).cast<String, dynamic>());
  }

  @override
  Future<void> save(NewGroupOperationJournal journal) async {
    saveCount += 1;
    if (throwBeforeSaveNumber == saveCount) throw StateError('FAKE_PROCESS_DEATH_BEFORE_DURABLE_SAVE');
    _json = jsonEncode(journal.toJson());
    if (throwAfterSaveNumber == saveCount) throw StateError('FAKE_PROCESS_DEATH_AFTER_DURABLE_SAVE');
  }

  void clearFailure() {
    throwBeforeSaveNumber = null;
    throwAfterSaveNumber = null;
  }
}

class FakeNewGroupProvider implements NewGroupProvider {
  FakeNewGroupProvider({
    required this.clock,
    this.accountIdentity = 'account-a',
    this.senderIdentity = 'sender-a',
    Set<FakeNewGroupInjection>? injections,
  }) : injections = injections ?? <FakeNewGroupInjection>{};

  final FakeNewGroupClock clock;
  final String accountIdentity;
  final String senderIdentity;
  final Set<FakeNewGroupInjection> injections;
  int capabilityReads = 0;
  int recipientReads = 0;
  int accountReads = 0;
  int senderReads = 0;
  int reserveInvocations = 0;
  int executeInvocations = 0;
  int physicalExecutions = 0;
  int observationInvocations = 0;
  int syntheticCallbackDeliveries = 0;
  int reconciliationInvocations = 0;
  NewGroupExecutionEnvelope? lastExecutionEnvelope;
  final Map<String, String> _reservations = <String, String>{};
  final Map<String, NewGroupExecutionReceipt> _receipts = <String, NewGroupExecutionReceipt>{};
  final Map<String, NewGroupObservedAppleResult> _observations = <String, NewGroupObservedAppleResult>{};

  @override
  Future<NewGroupProviderCapability> inspectCapabilities() async {
    capabilityReads += 1;
    final changed = injections.contains(FakeNewGroupInjection.providerRevisionChange) && capabilityReads > 1;
    return NewGroupProviderCapability(
      serverVersion: 'fake-safe-provider',
      evidenceRevision: changed ? 'provider-v2' : 'provider-v1',
      observedAtEpochMilliseconds: 900,
      validUntilEpochMilliseconds: 5000,
      privateApiEnabled: true,
      helperConnected: true,
      helperCreateActionAttested: true,
      iMessageGroupSupported:
          !(injections.contains(FakeNewGroupInjection.serviceChangeBeforeExecution) && capabilityReads > 1),
      smsMmsGroupSupported: true,
      explicitAccountBinding: true,
      explicitSenderBinding: true,
      operationIdempotency: true,
      appleObservation: true,
      attachmentFirstSend: true,
    );
  }

  @override
  Future<List<NewGroupRecipientEvidence>> resolveRecipients(NewLogicalConversationIntent intent) async {
    recipientReads += 1;
    final recipients = List<NewGroupRecipientEvidence>.of(intent.recipients);
    final disappearsBeforeExecution =
        injections.contains(FakeNewGroupInjection.recipientChangeBeforeExecution) && recipientReads > 1;
    if ((injections.contains(FakeNewGroupInjection.missingRecipient) || disappearsBeforeExecution) &&
        recipients.isNotEmpty) {
      recipients.removeLast();
    }
    if (injections.contains(FakeNewGroupInjection.extraRecipient)) {
      recipients.add(
        const NewGroupRecipientEvidence(
          selectionId: 'injected-extra',
          normalizedHandle: '+15559999999',
          isSelf: false,
          iMessageCapability: NewGroupRecipientCapability.available,
          smsMmsCapability: NewGroupRecipientCapability.available,
          resolutionRevision: 'injected-extra-v1',
          observedAtEpochMilliseconds: 900,
          validUntilEpochMilliseconds: 5000,
        ),
      );
    }
    return recipients;
  }

  @override
  Future<ProviderAccountIdentity> readAccountIdentity() async {
    accountReads += 1;
    final changedBeforeExecution =
        injections.contains(FakeNewGroupInjection.accountChangeBeforeExecution) && accountReads > 1;
    return ProviderAccountIdentity(
      stableIdentity: injections.contains(FakeNewGroupInjection.wrongAccount) || changedBeforeExecution
          ? 'account-wrong'
          : accountIdentity,
      evidenceRevision: 'account-v1',
      observedAtEpochMilliseconds: 900,
      validUntilEpochMilliseconds: 5000,
    );
  }

  @override
  Future<ProviderSenderIdentity> readSenderIdentity() async {
    senderReads += 1;
    final changedBeforeExecution =
        injections.contains(FakeNewGroupInjection.senderChangeBeforeExecution) && senderReads > 1;
    return ProviderSenderIdentity(
      stableIdentity: injections.contains(FakeNewGroupInjection.wrongSender) || changedBeforeExecution
          ? 'sender-wrong'
          : senderIdentity,
      accountIdentity: accountIdentity,
      evidenceRevision: 'sender-v1',
      observedAtEpochMilliseconds: 900,
      validUntilEpochMilliseconds: 5000,
    );
  }

  @override
  Future<List<ExistingPhysicalGroupEvidence>> findExactExistingGroups(NewLogicalConversationIntent intent) async {
    if (injections.contains(FakeNewGroupInjection.duplicatePhysicalGroup)) {
      return <ExistingPhysicalGroupEvidence>[
        _existing(intent, 'existing-a', false),
        _existing(intent, 'existing-b', true),
      ];
    }
    if (injections.contains(FakeNewGroupInjection.existingHistoricalExactGroup)) {
      return <ExistingPhysicalGroupEvidence>[_existing(intent, 'existing-historical', true)];
    }
    return <ExistingPhysicalGroupEvidence>[];
  }

  ExistingPhysicalGroupEvidence _existing(NewLogicalConversationIntent intent, String id, bool historical) {
    return ExistingPhysicalGroupEvidence(
      physicalIdentity: id,
      normalizedRecipients: intent.normalizedRecipientSet,
      service: intent.requestedService,
      accountIdentity: intent.expectedAccountIdentity,
      isHistorical: historical,
    );
  }

  @override
  Future<NewGroupProviderReservation> reserveOperation(NewGroupExecutionEnvelope envelope) async {
    reserveInvocations += 1;
    if (injections.contains(FakeNewGroupInjection.helperPreExecutionFailure)) {
      return const NewGroupProviderReservation(
        state: NewGroupProviderReservationState.rejected,
        reasonCode: 'FAKE_HELPER_PRE_EXECUTION_FAILURE',
      );
    }
    if (injections.contains(FakeNewGroupInjection.helperTimeoutBeforeExecution)) {
      return const NewGroupProviderReservation(
        state: NewGroupProviderReservationState.timeoutBeforeExecution,
        reasonCode: 'FAKE_TIMEOUT_BEFORE_EXECUTION',
      );
    }
    final reservation = _reservations.putIfAbsent(envelope.operationId, () => 'reservation-${envelope.operationId}');
    return NewGroupProviderReservation(
      state: NewGroupProviderReservationState.reserved,
      reservationId: reservation,
      reasonCode: 'RESERVED',
    );
  }

  @override
  Future<NewGroupExecutionReceipt> executeFirstSend(
    NewGroupExecutionEnvelope envelope,
    NewGroupProviderReservation reservation,
  ) async {
    executeInvocations += 1;
    lastExecutionEnvelope = envelope;
    if (_receipts.containsKey(envelope.operationId)) throw StateError('FAKE_DUPLICATE_EXECUTION');
    physicalExecutions += 1;
    final receipt = NewGroupExecutionReceipt(
      operationId: envelope.operationId,
      reservationId: reservation.reservationId!,
      providerRequestId: 'request-${envelope.operationId}',
      providerMessageIdentity: 'message-${envelope.operationId}',
      acceptedAtEpochMilliseconds: clock(),
    );
    _receipts[envelope.operationId] = receipt;
    _observations[envelope.operationId] = _observation(envelope, receipt);
    if (injections.contains(FakeNewGroupInjection.helperTimeoutAfterExecution) ||
        injections.contains(FakeNewGroupInjection.processDeath)) {
      throw StateError('FAKE_TIMEOUT_AFTER_EXECUTION');
    }
    return receipt;
  }

  NewGroupObservedAppleResult _observation(NewGroupExecutionEnvelope envelope, NewGroupExecutionReceipt receipt) {
    final recipients = List<String>.of(envelope.normalizedRecipients);
    if (injections.contains(FakeNewGroupInjection.missingObservationRecipient) && recipients.isNotEmpty) {
      recipients.removeLast();
    }
    if (injections.contains(FakeNewGroupInjection.extraObservationRecipient)) recipients.add('+15559999999');
    return NewGroupObservedAppleResult(
      operationId: envelope.operationId,
      providerRequestId: receipt.providerRequestId,
      chatGuid: 'iMessage;+;chat-${envelope.operationId}',
      chatRowId: 101,
      messageGuid: injections.contains(FakeNewGroupInjection.wrongObservationMessageIdentity)
          ? 'message-wrong'
          : receipt.providerMessageIdentity,
      messageRowId: 202,
      normalizedRecipients: recipients,
      service: injections.contains(FakeNewGroupInjection.serviceDowngrade)
          ? NewGroupRequestedService.smsMms
          : envelope.requestedService,
      accountIdentity: injections.contains(FakeNewGroupInjection.wrongObservationAccount)
          ? 'account-wrong'
          : envelope.accountIdentity,
      senderIdentity: injections.contains(FakeNewGroupInjection.wrongObservationSender)
          ? 'sender-wrong'
          : envelope.senderIdentity,
      observedAtEpochMilliseconds: clock(),
      isFromMe: true,
      isTerminallySent: true,
    );
  }

  @override
  Future<NewGroupObservedAppleResult?> observeAppleResult(
    NewGroupExecutionEnvelope envelope,
    NewGroupExecutionReceipt receipt,
  ) async {
    observationInvocations += 1;
    syntheticCallbackDeliveries += injections.contains(FakeNewGroupInjection.duplicateCallback) ? 2 : 1;
    if (injections.contains(FakeNewGroupInjection.delayedAppleObservation)) return null;
    return _observations[envelope.operationId];
  }

  @override
  Future<NewGroupReconciliationResult> reconcileAmbiguousOperation(NewGroupExecutionEnvelope envelope) async {
    reconciliationInvocations += 1;
    final observation = _observations[envelope.operationId];
    if (observation == null) {
      return const NewGroupReconciliationResult(
        state: NewGroupReconciliationState.provenNotExecuted,
        evidenceRevision: 'fake-not-executed-v1',
      );
    }
    return NewGroupReconciliationResult(
      state: NewGroupReconciliationState.provenSuccess,
      evidenceRevision: 'fake-success-${envelope.operationId}',
      observation: observation,
    );
  }
}
