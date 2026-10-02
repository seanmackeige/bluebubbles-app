import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:crypto/crypto.dart';
import 'package:synchronized/synchronized.dart';

const newGroupProviderContractSchema = 'NEW_GROUP_PROVIDER_CONTRACT_V1';
const newGroupOperationStateMachineSchema = 'NEW_GROUP_OPERATION_STATE_MACHINE_V1';

String _digest(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

T _enumValue<T extends Enum>(List<T> values, Object? name) {
  return values.singleWhere((value) => value.name == name);
}

enum NewGroupProviderOperationState {
  draft,
  validated,
  admitted,
  executionReserved,
  executionStarted,
  appleResultObserved,
  terminalSuccess,
  preExecutionRejected,
  outcomeAmbiguous,
}

enum NewGroupProviderReservationState { reserved, rejected, timeoutBeforeExecution }

enum NewGroupReconciliationState { provenSuccess, provenNotExecuted, stillAmbiguous }

/// Stable provider account identity plus a current, expiring evidence revision.
class ProviderAccountIdentity {
  const ProviderAccountIdentity({
    required this.stableIdentity,
    required this.evidenceRevision,
    required this.observedAtEpochMilliseconds,
    required this.validUntilEpochMilliseconds,
  });

  final String stableIdentity;
  final String evidenceRevision;
  final int observedAtEpochMilliseconds;
  final int validUntilEpochMilliseconds;

  bool isCurrentAt(int now) {
    return stableIdentity.isNotEmpty &&
        evidenceRevision.isNotEmpty &&
        observedAtEpochMilliseconds <= now &&
        now <= validUntilEpochMilliseconds;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'stableIdentity': stableIdentity,
    'evidenceRevision': evidenceRevision,
    'observedAtEpochMilliseconds': observedAtEpochMilliseconds,
    'validUntilEpochMilliseconds': validUntilEpochMilliseconds,
  };
}

/// Stable outbound sender identity. It is evidence, never an instruction to
/// mutate the active Apple sender.
class ProviderSenderIdentity {
  const ProviderSenderIdentity({
    required this.stableIdentity,
    required this.accountIdentity,
    required this.evidenceRevision,
    required this.observedAtEpochMilliseconds,
    required this.validUntilEpochMilliseconds,
  });

  final String stableIdentity;
  final String accountIdentity;
  final String evidenceRevision;
  final int observedAtEpochMilliseconds;
  final int validUntilEpochMilliseconds;

  bool isCurrentAt(int now) {
    return stableIdentity.isNotEmpty &&
        accountIdentity.isNotEmpty &&
        evidenceRevision.isNotEmpty &&
        observedAtEpochMilliseconds <= now &&
        now <= validUntilEpochMilliseconds;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'stableIdentity': stableIdentity,
    'accountIdentity': accountIdentity,
    'evidenceRevision': evidenceRevision,
    'observedAtEpochMilliseconds': observedAtEpochMilliseconds,
    'validUntilEpochMilliseconds': validUntilEpochMilliseconds,
  };
}

class NewGroupProviderAuthority {
  NewGroupProviderAuthority({
    required this.capability,
    required this.account,
    required this.sender,
    required List<NewGroupRecipientEvidence> recipients,
    required List<ExistingPhysicalGroupEvidence> existingGroups,
  }) : recipients = List<NewGroupRecipientEvidence>.unmodifiable(recipients),
       existingGroups = List<ExistingPhysicalGroupEvidence>.unmodifiable(existingGroups);

  final NewGroupProviderCapability capability;
  final ProviderAccountIdentity account;
  final ProviderSenderIdentity sender;
  final List<NewGroupRecipientEvidence> recipients;
  final List<ExistingPhysicalGroupEvidence> existingGroups;

  String get revision => _digest(<String, dynamic>{
    'schema': newGroupProviderContractSchema,
    'capabilityRevision': capability.revision,
    'account': account.toJson(),
    'sender': sender.toJson(),
    'recipients': recipients.map((value) => value.toJson()).toList(growable: false)
      ..sort((a, b) => (a['selectionId'] as String).compareTo(b['selectionId'] as String)),
    'existingGroups': existingGroups.map((value) => value.toEvidenceJson()).toList(growable: false)
      ..sort((a, b) => (a['physicalIdentity'] as String).compareTo(b['physicalIdentity'] as String)),
  });
}

class NewGroupExecutionEnvelope {
  NewGroupExecutionEnvelope({
    required this.operationId,
    required this.operationBindingFingerprint,
    required this.providerRevision,
    required List<String> normalizedRecipients,
    required this.recipientFingerprint,
    required this.requestedService,
    required this.accountIdentity,
    required this.senderIdentity,
    required this.draftText,
    required this.draftContentFingerprint,
    required List<NewGroupAttachmentIntent> attachments,
  }) : normalizedRecipients = List<String>.unmodifiable(normalizedRecipients),
       attachments = List<NewGroupAttachmentIntent>.unmodifiable(attachments);

  final String operationId;
  final String operationBindingFingerprint;
  final String providerRevision;
  final List<String> normalizedRecipients;
  final String recipientFingerprint;
  final NewGroupRequestedService requestedService;
  final String accountIdentity;
  final String senderIdentity;
  final String draftText;
  final String draftContentFingerprint;
  final List<NewGroupAttachmentIntent> attachments;

  factory NewGroupExecutionEnvelope.fromIntent(NewLogicalConversationIntent intent, String providerRevision) {
    return NewGroupExecutionEnvelope(
      operationId: intent.operationId,
      operationBindingFingerprint: intent.operationBindingFingerprint,
      providerRevision: providerRevision,
      normalizedRecipients: intent.normalizedRecipientSet,
      recipientFingerprint: _digest(intent.normalizedRecipientSet),
      requestedService: intent.requestedService,
      accountIdentity: intent.expectedAccountIdentity,
      senderIdentity: intent.expectedSenderIdentity,
      draftText: intent.draftText,
      draftContentFingerprint: intent.draftContentFingerprint,
      attachments: intent.attachments,
    );
  }
}

class NewGroupProviderReservation {
  const NewGroupProviderReservation({required this.state, this.reservationId, required this.reasonCode});

  final NewGroupProviderReservationState state;
  final String? reservationId;
  final String reasonCode;

  bool get isReserved => state == NewGroupProviderReservationState.reserved && reservationId != null;
}

class NewGroupProviderRejectedBeforeDispatch implements Exception {
  const NewGroupProviderRejectedBeforeDispatch({
    required this.operationId,
    required this.reservationId,
    required this.executionStarted,
    required this.providerRevision,
    required this.accountIdentity,
    required this.senderIdentity,
    required this.service,
    required this.reasonCode,
  });

  final String operationId;
  final String reservationId;
  final bool executionStarted;
  final String providerRevision;
  final String accountIdentity;
  final String senderIdentity;
  final NewGroupRequestedService service;
  final String reasonCode;

  bool exactlyMatches(NewGroupExecutionEnvelope envelope, NewGroupProviderReservation reservation) {
    return !executionStarted &&
        reservationId == reservation.reservationId &&
        operationId == envelope.operationId &&
        providerRevision == envelope.providerRevision &&
        accountIdentity == envelope.accountIdentity &&
        senderIdentity == envelope.senderIdentity &&
        service == envelope.requestedService;
  }
}

class NewGroupExecutionReceipt {
  const NewGroupExecutionReceipt({
    required this.operationId,
    required this.reservationId,
    required this.providerRequestId,
    required this.providerMessageIdentity,
    required this.providerAccountIdentity,
    required this.providerSenderIdentity,
    required this.service,
    required this.executionStarted,
    required this.acceptedAtEpochMilliseconds,
  });

  final String operationId;
  final String reservationId;
  final String providerRequestId;
  final String providerMessageIdentity;
  final String providerAccountIdentity;
  final String providerSenderIdentity;
  final NewGroupRequestedService service;
  final bool executionStarted;
  final int acceptedAtEpochMilliseconds;
}

/// Strong Apple-created result evidence. Message text is intentionally absent
/// as a correlation key; operation, provider request, message, participant,
/// service, account, sender, and time evidence must agree.
class NewGroupObservedAppleResult {
  NewGroupObservedAppleResult({
    required this.operationId,
    required this.providerRequestId,
    required this.chatGuid,
    required this.chatRowId,
    required this.messageGuid,
    required this.messageRowId,
    required List<String> normalizedRecipients,
    required this.service,
    required this.accountIdentity,
    required this.senderIdentity,
    required this.observedAtEpochMilliseconds,
    required this.isFromMe,
    required this.isTerminallySent,
  }) : normalizedRecipients = List<String>.unmodifiable(List<String>.of(normalizedRecipients)..sort());

  final String operationId;
  final String providerRequestId;
  final String chatGuid;
  final int chatRowId;
  final String messageGuid;
  final int messageRowId;
  final List<String> normalizedRecipients;
  final NewGroupRequestedService service;
  final String accountIdentity;
  final String senderIdentity;
  final int observedAtEpochMilliseconds;
  final bool isFromMe;
  final bool isTerminallySent;

  bool exactlyMatches({
    required NewLogicalConversationIntent intent,
    required String expectedProviderRequestId,
    required String expectedProviderMessageIdentity,
    required int executionStartedAtEpochMilliseconds,
  }) {
    if (operationId != intent.operationId ||
        providerRequestId != expectedProviderRequestId ||
        messageGuid != expectedProviderMessageIdentity ||
        chatGuid.isEmpty ||
        chatRowId <= 0 ||
        messageGuid.isEmpty ||
        messageRowId <= 0 ||
        service != intent.requestedService ||
        accountIdentity != intent.expectedAccountIdentity ||
        senderIdentity != intent.expectedSenderIdentity ||
        observedAtEpochMilliseconds < executionStartedAtEpochMilliseconds ||
        !isFromMe ||
        !isTerminallySent) {
      return false;
    }
    final expected = intent.normalizedRecipientSet;
    if (normalizedRecipients.length != expected.length || normalizedRecipients.toSet().length != expected.length) {
      return false;
    }
    for (var index = 0; index < expected.length; index++) {
      if (normalizedRecipients[index] != expected[index]) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'operationId': operationId,
    'providerRequestId': providerRequestId,
    'chatGuid': chatGuid,
    'chatRowId': chatRowId,
    'messageGuid': messageGuid,
    'messageRowId': messageRowId,
    'normalizedRecipients': normalizedRecipients,
    'service': service.name,
    'accountIdentity': accountIdentity,
    'senderIdentity': senderIdentity,
    'observedAtEpochMilliseconds': observedAtEpochMilliseconds,
    'isFromMe': isFromMe,
    'isTerminallySent': isTerminallySent,
  };

  factory NewGroupObservedAppleResult.fromJson(Map<String, dynamic> json) {
    return NewGroupObservedAppleResult(
      operationId: json['operationId'] as String,
      providerRequestId: json['providerRequestId'] as String,
      chatGuid: json['chatGuid'] as String,
      chatRowId: (json['chatRowId'] as num).toInt(),
      messageGuid: json['messageGuid'] as String,
      messageRowId: (json['messageRowId'] as num).toInt(),
      normalizedRecipients: (json['normalizedRecipients'] as List).cast<String>(),
      service: _enumValue(NewGroupRequestedService.values, json['service']),
      accountIdentity: json['accountIdentity'] as String,
      senderIdentity: json['senderIdentity'] as String,
      observedAtEpochMilliseconds: (json['observedAtEpochMilliseconds'] as num).toInt(),
      isFromMe: json['isFromMe'] as bool,
      isTerminallySent: json['isTerminallySent'] as bool,
    );
  }
}

class NewGroupReconciliationResult {
  const NewGroupReconciliationResult({required this.state, required this.evidenceRevision, this.observation});

  final NewGroupReconciliationState state;
  final String evidenceRevision;
  final NewGroupObservedAppleResult? observation;
}

/// The only surface permitted to reach a group-creation implementation.
/// Production UI code must not invoke `/chat/new` or helper actions directly.
abstract interface class NewGroupProvider {
  Future<NewGroupProviderCapability> inspectCapabilities();

  Future<List<NewGroupRecipientEvidence>> resolveRecipients(NewLogicalConversationIntent intent);

  Future<ProviderAccountIdentity> readAccountIdentity();

  Future<ProviderSenderIdentity> readSenderIdentity();

  Future<List<ExistingPhysicalGroupEvidence>> findExactExistingGroups(NewLogicalConversationIntent intent);

  /// Reserves a provider-side operation ID without creating a chat or sending.
  Future<NewGroupProviderReservation> reserveOperation(NewGroupExecutionEnvelope envelope);

  /// This is the single physical first-send boundary.
  Future<NewGroupExecutionReceipt> executeFirstSend(
    NewGroupExecutionEnvelope envelope,
    NewGroupProviderReservation reservation,
  );

  Future<NewGroupObservedAppleResult?> observeAppleResult(
    NewGroupExecutionEnvelope envelope,
    NewGroupExecutionReceipt receipt,
  );

  Future<NewGroupReconciliationResult> reconcileAmbiguousOperation(NewGroupExecutionEnvelope envelope);
}

class NewGroupTransition {
  const NewGroupTransition({
    required this.sequence,
    required this.state,
    required this.atEpochMilliseconds,
    required this.reasonCode,
  });

  final int sequence;
  final NewGroupProviderOperationState state;
  final int atEpochMilliseconds;
  final String reasonCode;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sequence': sequence,
    'state': state.name,
    'atEpochMilliseconds': atEpochMilliseconds,
    'reasonCode': reasonCode,
  };

  factory NewGroupTransition.fromJson(Map<String, dynamic> json) {
    return NewGroupTransition(
      sequence: (json['sequence'] as num).toInt(),
      state: _enumValue(NewGroupProviderOperationState.values, json['state']),
      atEpochMilliseconds: (json['atEpochMilliseconds'] as num).toInt(),
      reasonCode: json['reasonCode'] as String,
    );
  }
}

class NewGroupDurableOperation {
  NewGroupDurableOperation({
    required this.intent,
    required this.state,
    required this.operationBindingFingerprint,
    required this.providerRevision,
    required this.admissionEvidenceRevision,
    required this.reasonCode,
    required this.dispatchInvocationCount,
    required this.executionStartedAtEpochMilliseconds,
    required this.providerReservationId,
    required this.providerRequestId,
    required this.providerMessageIdentity,
    required this.appleResult,
    required List<NewGroupTransition> transitions,
  }) : transitions = List<NewGroupTransition>.unmodifiable(transitions);

  factory NewGroupDurableOperation.draft(NewLogicalConversationIntent intent, int now) {
    return NewGroupDurableOperation(
      intent: intent,
      state: NewGroupProviderOperationState.draft,
      operationBindingFingerprint: intent.operationBindingFingerprint,
      providerRevision: null,
      admissionEvidenceRevision: null,
      reasonCode: 'DRAFT_CAPTURED',
      dispatchInvocationCount: 0,
      executionStartedAtEpochMilliseconds: null,
      providerReservationId: null,
      providerRequestId: null,
      providerMessageIdentity: null,
      appleResult: null,
      transitions: <NewGroupTransition>[
        NewGroupTransition(
          sequence: 0,
          state: NewGroupProviderOperationState.draft,
          atEpochMilliseconds: now,
          reasonCode: 'DRAFT_CAPTURED',
        ),
      ],
    );
  }

  final NewLogicalConversationIntent intent;
  final NewGroupProviderOperationState state;
  final String operationBindingFingerprint;
  final String? providerRevision;
  final String? admissionEvidenceRevision;
  final String reasonCode;
  final int dispatchInvocationCount;
  final int? executionStartedAtEpochMilliseconds;
  final String? providerReservationId;
  final String? providerRequestId;
  final String? providerMessageIdentity;
  final NewGroupObservedAppleResult? appleResult;
  final List<NewGroupTransition> transitions;

  bool get automaticReplayForbidden =>
      dispatchInvocationCount > 0 ||
      state == NewGroupProviderOperationState.executionStarted ||
      state == NewGroupProviderOperationState.appleResultObserved ||
      state == NewGroupProviderOperationState.terminalSuccess ||
      state == NewGroupProviderOperationState.outcomeAmbiguous;

  NewGroupDurableOperation transition(
    NewGroupProviderOperationState next,
    int now,
    String reason, {
    NewLogicalConversationIntent? intent,
    String? providerRevision,
    String? admissionEvidenceRevision,
    int? dispatchInvocationCount,
    int? executionStartedAtEpochMilliseconds,
    String? providerReservationId,
    String? providerRequestId,
    String? providerMessageIdentity,
    NewGroupObservedAppleResult? appleResult,
  }) {
    return NewGroupDurableOperation(
      intent: intent ?? this.intent,
      state: next,
      operationBindingFingerprint: operationBindingFingerprint,
      providerRevision: providerRevision ?? this.providerRevision,
      admissionEvidenceRevision: admissionEvidenceRevision ?? this.admissionEvidenceRevision,
      reasonCode: reason,
      dispatchInvocationCount: dispatchInvocationCount ?? this.dispatchInvocationCount,
      executionStartedAtEpochMilliseconds:
          executionStartedAtEpochMilliseconds ?? this.executionStartedAtEpochMilliseconds,
      providerReservationId: providerReservationId ?? this.providerReservationId,
      providerRequestId: providerRequestId ?? this.providerRequestId,
      providerMessageIdentity: providerMessageIdentity ?? this.providerMessageIdentity,
      appleResult: appleResult ?? this.appleResult,
      transitions: <NewGroupTransition>[
        ...transitions,
        NewGroupTransition(sequence: transitions.length, state: next, atEpochMilliseconds: now, reasonCode: reason),
      ],
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'intent': intent.toJson(),
    'state': state.name,
    'operationBindingFingerprint': operationBindingFingerprint,
    'providerRevision': providerRevision,
    'admissionEvidenceRevision': admissionEvidenceRevision,
    'reasonCode': reasonCode,
    'dispatchInvocationCount': dispatchInvocationCount,
    'executionStartedAtEpochMilliseconds': executionStartedAtEpochMilliseconds,
    'providerReservationId': providerReservationId,
    'providerRequestId': providerRequestId,
    'providerMessageIdentity': providerMessageIdentity,
    'appleResult': appleResult?.toJson(),
    'transitions': transitions.map((value) => value.toJson()).toList(growable: false),
  };

  factory NewGroupDurableOperation.fromJson(Map<String, dynamic> json) {
    final transitions = (json['transitions'] as List)
        .map((value) => NewGroupTransition.fromJson((value as Map).cast<String, dynamic>()))
        .toList(growable: false);
    for (var index = 0; index < transitions.length; index++) {
      if (transitions[index].sequence != index) throw const FormatException('Invalid operation transition sequence');
    }
    final intent = NewLogicalConversationIntent.fromJson((json['intent'] as Map).cast<String, dynamic>());
    final binding = json['operationBindingFingerprint'] as String;
    if (binding != intent.operationBindingFingerprint) {
      throw const FormatException('Operation binding fingerprint mismatch');
    }
    return NewGroupDurableOperation(
      intent: intent,
      state: _enumValue(NewGroupProviderOperationState.values, json['state']),
      operationBindingFingerprint: binding,
      providerRevision: json['providerRevision'] as String?,
      admissionEvidenceRevision: json['admissionEvidenceRevision'] as String?,
      reasonCode: json['reasonCode'] as String,
      dispatchInvocationCount: (json['dispatchInvocationCount'] as num).toInt(),
      executionStartedAtEpochMilliseconds: (json['executionStartedAtEpochMilliseconds'] as num?)?.toInt(),
      providerReservationId: json['providerReservationId'] as String?,
      providerRequestId: json['providerRequestId'] as String?,
      providerMessageIdentity: json['providerMessageIdentity'] as String?,
      appleResult: json['appleResult'] == null
          ? null
          : NewGroupObservedAppleResult.fromJson((json['appleResult'] as Map).cast<String, dynamic>()),
      transitions: transitions,
    );
  }
}

class NewGroupOperationJournal {
  NewGroupOperationJournal._(this._operations);

  factory NewGroupOperationJournal.empty() => NewGroupOperationJournal._(<String, NewGroupDurableOperation>{});

  factory NewGroupOperationJournal.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != newGroupOperationStateMachineSchema) {
      throw const FormatException('Unsupported new-group journal schema');
    }
    final operations = <String, NewGroupDurableOperation>{};
    for (final raw in json['operations'] as List) {
      final operation = NewGroupDurableOperation.fromJson((raw as Map).cast<String, dynamic>());
      if (operations.containsKey(operation.intent.operationId)) {
        throw const FormatException('Duplicate operation identity');
      }
      operations[operation.intent.operationId] = operation;
    }
    return NewGroupOperationJournal._(operations);
  }

  final Map<String, NewGroupDurableOperation> _operations;

  NewGroupDurableOperation? operationFor(String operationId) => _operations[operationId];

  List<NewGroupDurableOperation> get operations => List<NewGroupDurableOperation>.unmodifiable(_operations.values);

  void put(NewGroupDurableOperation operation) {
    final existing = _operations[operation.intent.operationId];
    if (existing != null && existing.operationBindingFingerprint != operation.operationBindingFingerprint) {
      throw StateError('OPERATION_ID_REBOUND_TO_DIFFERENT_INTENT');
    }
    _operations[operation.intent.operationId] = operation;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': newGroupOperationStateMachineSchema,
    'operations': _operations.values.map((value) => value.toJson()).toList(growable: false)
      ..sort(
        (a, b) =>
            ((a['intent'] as Map)['operationId'] as String).compareTo((b['intent'] as Map)['operationId'] as String),
      ),
  };
}

abstract interface class NewGroupOperationStore {
  Future<NewGroupOperationJournal> load();

  /// Completion means the complete journal replacement is durable enough to
  /// be the sole authority used before the next physical boundary.
  Future<void> save(NewGroupOperationJournal journal);
}

class NewGroupProviderCoordinator {
  NewGroupProviderCoordinator({required this.provider, required this.store, required this.now});

  final NewGroupProvider provider;
  final NewGroupOperationStore store;
  final int Function() now;
  final Lock _lock = Lock();

  Future<NewGroupProviderAuthority> _readAuthority(NewLogicalConversationIntent intent) async {
    final capability = await provider.inspectCapabilities();
    final recipients = await provider.resolveRecipients(intent);
    final account = await provider.readAccountIdentity();
    final sender = await provider.readSenderIdentity();
    final resolvedIntent = _intentWithRecipients(intent, recipients);
    final existing = await provider.findExactExistingGroups(resolvedIntent);
    return NewGroupProviderAuthority(
      capability: capability,
      account: account,
      sender: sender,
      recipients: recipients,
      existingGroups: existing,
    );
  }

  NewLogicalConversationIntent _intentWithRecipients(
    NewLogicalConversationIntent intent,
    List<NewGroupRecipientEvidence> recipients,
  ) {
    return NewLogicalConversationIntent(
      operationId: intent.operationId,
      recipients: recipients,
      requestedService: intent.requestedService,
      expectedAccountIdentity: intent.expectedAccountIdentity,
      expectedSenderIdentity: intent.expectedSenderIdentity,
      draftText: intent.draftText,
      attachments: intent.attachments,
      contentRevision: intent.contentRevision,
      createdAtEpochMilliseconds: intent.createdAtEpochMilliseconds,
    );
  }

  bool _sameHumanRecipientIntent(NewLogicalConversationIntent original, List<NewGroupRecipientEvidence> resolved) {
    if (original.recipients.length != resolved.length) return false;
    final originalSelections = original.recipients.map((value) => value.selectionId).toSet();
    final resolvedSelections = resolved.map((value) => value.selectionId).toSet();
    if (originalSelections.length != original.recipients.length || resolvedSelections.length != resolved.length) {
      return false;
    }
    return originalSelections.containsAll(resolvedSelections) && resolvedSelections.containsAll(originalSelections);
  }

  NewGroupPreflightResult _preflight(
    NewLogicalConversationIntent intent,
    NewGroupProviderAuthority authority,
    int currentTime,
  ) {
    if (authority.sender.accountIdentity != authority.account.stableIdentity) {
      return NewGroupPreflightResult(
        state: NewGroupPreflightState.blocked,
        reason: NewGroupFailureReason.accountMismatch,
        userMessage: 'Group creation blocked — sender account does not match',
        evidenceRevision: authority.revision,
      );
    }
    return NewGroupPreflight.evaluate(
      intent: intent,
      provider: authority.capability,
      accountProof: NewGroupAccountProof(
        accountIdentity: authority.account.stableIdentity,
        senderIdentity: authority.sender.stableIdentity,
        evidenceRevision: _digest(<String, dynamic>{
          'account': authority.account.toJson(),
          'sender': authority.sender.toJson(),
        }),
        observedAtEpochMilliseconds:
            authority.account.observedAtEpochMilliseconds > authority.sender.observedAtEpochMilliseconds
            ? authority.account.observedAtEpochMilliseconds
            : authority.sender.observedAtEpochMilliseconds,
        validUntilEpochMilliseconds:
            authority.account.validUntilEpochMilliseconds < authority.sender.validUntilEpochMilliseconds
            ? authority.account.validUntilEpochMilliseconds
            : authority.sender.validUntilEpochMilliseconds,
      ),
      existingGroups: authority.existingGroups,
      nowEpochMilliseconds: currentTime,
    );
  }

  Future<void> _persist(NewGroupOperationJournal journal, NewGroupDurableOperation operation) async {
    journal.put(operation);
    await store.save(journal);
  }

  /// Persists DRAFT, VALIDATED and ADMITTED as separate durable boundaries.
  /// Duplicate taps with the same operation identity return the existing
  /// operation and never create a second admission.
  Future<NewGroupDurableOperation> prepare(NewLogicalConversationIntent intent) {
    return _lock.synchronized(() async {
      final journal = await store.load();
      final existing = journal.operationFor(intent.operationId);
      NewGroupDurableOperation operation;
      if (existing != null) {
        if (existing.operationBindingFingerprint != intent.operationBindingFingerprint) {
          throw StateError('OPERATION_ID_REBOUND_TO_DIFFERENT_INTENT');
        }
        if (existing.state != NewGroupProviderOperationState.draft &&
            existing.state != NewGroupProviderOperationState.validated) {
          return existing;
        }
        operation = existing;
      } else {
        operation = NewGroupDurableOperation.draft(intent, now());
        await _persist(journal, operation);
      }

      NewGroupProviderAuthority authority;
      try {
        authority = await _readAuthority(intent);
      } catch (_) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          'PROVIDER_EVIDENCE_UNAVAILABLE_BEFORE_EXECUTION',
        );
        await _persist(journal, operation);
        return operation;
      }
      final resolvedIntent = _intentWithRecipients(intent, authority.recipients);
      if (!_sameHumanRecipientIntent(intent, authority.recipients) ||
          resolvedIntent.operationBindingFingerprint != intent.operationBindingFingerprint) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          'RECIPIENT_RESOLUTION_CHANGED_HUMAN_INTENT',
        );
        await _persist(journal, operation);
        return operation;
      }

      final currentTime = now();
      final preflight = _preflight(resolvedIntent, authority, currentTime);
      operation = operation.transition(
        NewGroupProviderOperationState.validated,
        currentTime,
        'VALIDATED_EXACT_PROVIDER_EVIDENCE',
        intent: resolvedIntent,
        providerRevision: authority.revision,
        admissionEvidenceRevision: preflight.evidenceRevision,
      );
      await _persist(journal, operation);

      if (!preflight.isReady) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          'PRE_EXECUTION_${preflight.reason.name.toUpperCase()}',
        );
        await _persist(journal, operation);
        return operation;
      }

      operation = operation.transition(
        NewGroupProviderOperationState.admitted,
        now(),
        'ADMITTED_EXACT_PROVIDER_REVISION',
      );
      await _persist(journal, operation);
      return operation;
    });
  }

  Future<NewGroupDurableOperation> execute(String operationId) {
    return _lock.synchronized(() async {
      final journal = await store.load();
      var operation = journal.operationFor(operationId);
      if (operation == null) throw StateError('UNKNOWN_NEW_GROUP_OPERATION');
      if (operation.state != NewGroupProviderOperationState.admitted || operation.automaticReplayForbidden) {
        return operation;
      }

      late NewGroupProviderAuthority authority;
      try {
        authority = await _readAuthority(operation.intent);
      } catch (_) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          'PROVIDER_EVIDENCE_UNAVAILABLE_BEFORE_EXECUTION',
        );
        await _persist(journal, operation);
        return operation;
      }
      final currentTime = now();
      final resolvedIntent = _intentWithRecipients(operation.intent, authority.recipients);
      final preflight = _preflight(resolvedIntent, authority, currentTime);
      final unchanged =
          _sameHumanRecipientIntent(operation.intent, authority.recipients) &&
          resolvedIntent.operationBindingFingerprint == operation.operationBindingFingerprint &&
          authority.revision == operation.providerRevision &&
          preflight.evidenceRevision == operation.admissionEvidenceRevision &&
          preflight.isReady;
      if (!unchanged) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          currentTime,
          'PROVIDER_AUTHORITY_CHANGED_BEFORE_EXECUTION',
        );
        await _persist(journal, operation);
        return operation;
      }

      final envelope = NewGroupExecutionEnvelope.fromIntent(operation.intent, authority.revision);
      operation = operation.transition(
        NewGroupProviderOperationState.executionReserved,
        now(),
        'LOCAL_EXECUTION_RESERVED',
      );
      await _persist(journal, operation);

      NewGroupProviderReservation reservation;
      try {
        reservation = await provider.reserveOperation(envelope);
      } catch (_) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          'PROVIDER_RESERVATION_UNAVAILABLE_BEFORE_EXECUTION',
        );
        await _persist(journal, operation);
        return operation;
      }
      if (!reservation.isReserved) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          reservation.reasonCode,
        );
        await _persist(journal, operation);
        return operation;
      }

      operation = operation.transition(
        NewGroupProviderOperationState.executionReserved,
        now(),
        'PROVIDER_OPERATION_RESERVED',
        providerReservationId: reservation.reservationId,
      );
      await _persist(journal, operation);

      final startedAt = now();
      operation = operation.transition(
        NewGroupProviderOperationState.executionStarted,
        startedAt,
        'EXECUTION_STARTED_NO_AUTOMATIC_REPLAY',
        dispatchInvocationCount: 1,
        executionStartedAtEpochMilliseconds: startedAt,
      );
      await _persist(journal, operation);

      NewGroupExecutionReceipt receipt;
      try {
        receipt = await provider.executeFirstSend(envelope, reservation);
      } on NewGroupProviderRejectedBeforeDispatch catch (rejection) {
        if (!rejection.exactlyMatches(envelope, reservation)) {
          operation = operation.transition(
            NewGroupProviderOperationState.outcomeAmbiguous,
            now(),
            'PROVIDER_REJECTION_IDENTITY_MISMATCH',
          );
        } else {
          operation = operation.transition(
            NewGroupProviderOperationState.preExecutionRejected,
            now(),
            rejection.reasonCode,
          );
        }
        await _persist(journal, operation);
        return operation;
      } catch (_) {
        operation = operation.transition(
          NewGroupProviderOperationState.outcomeAmbiguous,
          now(),
          'NEW_GROUP_OUTCOME_AMBIGUOUS',
        );
        await _persist(journal, operation);
        return operation;
      }
      if (receipt.operationId != operationId ||
          receipt.reservationId != reservation.reservationId ||
          receipt.providerRequestId.isEmpty ||
          receipt.providerMessageIdentity.isEmpty ||
          !receipt.executionStarted ||
          receipt.providerAccountIdentity != envelope.accountIdentity ||
          receipt.providerSenderIdentity != envelope.senderIdentity ||
          receipt.service != envelope.requestedService) {
        operation = operation.transition(
          NewGroupProviderOperationState.outcomeAmbiguous,
          now(),
          'PROVIDER_RECEIPT_IDENTITY_MISMATCH',
        );
        await _persist(journal, operation);
        return operation;
      }
      operation = operation.transition(
        NewGroupProviderOperationState.executionStarted,
        now(),
        'PROVIDER_RECEIPT_OBSERVED',
        providerRequestId: receipt.providerRequestId,
        providerMessageIdentity: receipt.providerMessageIdentity,
      );
      await _persist(journal, operation);

      NewGroupObservedAppleResult? observation;
      try {
        observation = await provider.observeAppleResult(envelope, receipt);
      } catch (_) {
        observation = null;
      }
      if (observation == null ||
          !observation.exactlyMatches(
            intent: operation.intent,
            expectedProviderRequestId: receipt.providerRequestId,
            expectedProviderMessageIdentity: receipt.providerMessageIdentity,
            executionStartedAtEpochMilliseconds: startedAt,
          )) {
        operation = operation.transition(
          NewGroupProviderOperationState.outcomeAmbiguous,
          now(),
          'NEW_GROUP_OUTCOME_AMBIGUOUS',
        );
        await _persist(journal, operation);
        return operation;
      }
      operation = operation.transition(
        NewGroupProviderOperationState.appleResultObserved,
        now(),
        'EXACT_APPLE_RESULT_OBSERVED',
        appleResult: observation,
      );
      await _persist(journal, operation);
      operation = operation.transition(NewGroupProviderOperationState.terminalSuccess, now(), 'TERMINAL_SUCCESS');
      await _persist(journal, operation);
      return operation;
    });
  }

  Future<NewGroupDurableOperation> reconcile(String operationId) {
    return _lock.synchronized(() async {
      final journal = await store.load();
      var operation = journal.operationFor(operationId);
      if (operation == null) throw StateError('UNKNOWN_NEW_GROUP_OPERATION');
      if (operation.state != NewGroupProviderOperationState.outcomeAmbiguous) return operation;
      final envelope = NewGroupExecutionEnvelope.fromIntent(operation.intent, operation.providerRevision ?? '');
      NewGroupReconciliationResult result;
      try {
        result = await provider.reconcileAmbiguousOperation(envelope);
      } catch (_) {
        return operation;
      }
      if (result.state == NewGroupReconciliationState.stillAmbiguous) return operation;
      if (result.state == NewGroupReconciliationState.provenNotExecuted) {
        operation = operation.transition(
          NewGroupProviderOperationState.preExecutionRejected,
          now(),
          'RECONCILED_PROVEN_NOT_EXECUTED_FRESH_HUMAN_ACTION_REQUIRED',
        );
        await _persist(journal, operation);
        return operation;
      }
      final observation = result.observation;
      final startedAt = operation.executionStartedAtEpochMilliseconds;
      final requestId = operation.providerRequestId ?? observation?.providerRequestId;
      final messageIdentity = operation.providerMessageIdentity ?? observation?.messageGuid;
      if (observation == null ||
          startedAt == null ||
          requestId == null ||
          messageIdentity == null ||
          !observation.exactlyMatches(
            intent: operation.intent,
            expectedProviderRequestId: requestId,
            expectedProviderMessageIdentity: messageIdentity,
            executionStartedAtEpochMilliseconds: startedAt,
          )) {
        return operation;
      }
      operation = operation.transition(
        NewGroupProviderOperationState.appleResultObserved,
        now(),
        'RECONCILED_EXACT_APPLE_RESULT',
        providerRequestId: requestId,
        providerMessageIdentity: messageIdentity,
        appleResult: observation,
      );
      await _persist(journal, operation);
      operation = operation.transition(
        NewGroupProviderOperationState.terminalSuccess,
        now(),
        'TERMINAL_SUCCESS_AFTER_RECONCILIATION',
      );
      await _persist(journal, operation);
      return operation;
    });
  }

  Future<List<NewGroupDurableOperation>> recoverAfterRestart() {
    return _lock.synchronized(() async {
      final journal = await store.load();
      var changed = false;
      for (final original in journal.operations) {
        var operation = original;
        if (operation.state == NewGroupProviderOperationState.executionReserved) {
          operation = operation.transition(
            NewGroupProviderOperationState.preExecutionRejected,
            now(),
            'INTERRUPTED_AFTER_RESERVATION_BEFORE_EXECUTION',
          );
        } else if (operation.state == NewGroupProviderOperationState.executionStarted) {
          operation = operation.transition(
            NewGroupProviderOperationState.outcomeAmbiguous,
            now(),
            'NEW_GROUP_OUTCOME_AMBIGUOUS_AFTER_RESTART',
          );
        } else if (operation.state == NewGroupProviderOperationState.appleResultObserved) {
          operation = operation.transition(
            NewGroupProviderOperationState.terminalSuccess,
            now(),
            'TERMINAL_SUCCESS_RECOVERED_FROM_DURABLE_APPLE_RESULT',
          );
        }
        if (!identical(operation, original)) {
          journal.put(operation);
          changed = true;
        }
      }
      if (changed) await store.save(journal);
      return journal.operations;
    });
  }
}

class NewGroupUiGateDecision {
  const NewGroupUiGateDecision({required this.mayInvokeCreateEndpoint, required this.userMessage});
  final bool mayInvokeCreateEndpoint;
  final String userMessage;
}

class NewGroupBuild100UiGate {
  const NewGroupBuild100UiGate._();
  static NewGroupUiGateDecision evaluate({
    required int recipientCount,
    required NewGroupRequestedService requestedService,
    required Iterable<NewGroupRecipientCapability> recipientCapabilities,
  }) {
    if (recipientCount < 2) return const NewGroupUiGateDecision(mayInvokeCreateEndpoint: true, userMessage: '');
    if (recipientCapabilities.any((value) => value == NewGroupRecipientCapability.unavailable)) {
      return NewGroupUiGateDecision(
        mayInvokeCreateEndpoint: false,
        userMessage: requestedService == NewGroupRequestedService.iMessage
            ? 'Recipient unavailable for iMessage'
            : 'Recipient unavailable for SMS/MMS',
      );
    }
    if (recipientCapabilities.any((value) => value == NewGroupRecipientCapability.unknown)) {
      return const NewGroupUiGateDecision(
        mayInvokeCreateEndpoint: false,
        userMessage: 'Group creation unavailable — recipient capability not verified',
      );
    }
    return const NewGroupUiGateDecision(
      mayInvokeCreateEndpoint: false,
      userMessage: 'Group creation unavailable — safe provider operation contract missing',
    );
  }
}
