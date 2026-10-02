import 'dart:convert';

import 'package:crypto/crypto.dart';

const newGroupIntentSchema = 'NEW_LOGICAL_CONVERSATION_INTENT_V1';
const newGroupCapabilitySchema = 'NEW_GROUP_PROVIDER_CAPABILITY_V1';
const newGroupOperationSchema = 'NEW_GROUP_OPERATION_V1';

enum NewGroupRequestedService { iMessage, smsMms }

enum NewGroupRecipientCapability { available, unavailable, unknown }

enum NewGroupExistingMatchState { none, exactCurrent, exactHistorical, multipleExact }

enum NewGroupProviderCapabilityState {
  groupCreateUnavailable,
  appleScriptSingleOnly,
  privateRoutePresentUnattested,
  privateRouteAttestedUnsafeContract,
  privateRouteSafeOffline,
  privateRouteReadyForHumanAuthorizedExecution,
}

enum NewGroupPreflightState { ready, blocked, existingSelectionRequired }

enum NewGroupOperationState { admitted, executionStarted, succeeded, blockedBeforeExecution, outcomeAmbiguous }

enum NewGroupFailureReason {
  none,
  invalidOperationIdentity,
  tooFewRecipients,
  duplicateRecipient,
  selfRecipient,
  staleRecipientResolution,
  recipientUnavailable,
  recipientCapabilityUnknown,
  serviceUnsupported,
  privateApiUnavailable,
  helperUnavailable,
  helperCreateActionUnattested,
  accountProofMissing,
  accountMismatch,
  senderMismatch,
  accountBindingUnsupported,
  senderBindingUnsupported,
  operationIdempotencyUnsupported,
  appleObservationUnsupported,
  attachmentFirstSendUnsupported,
  emptyFirstSend,
  existingGroupRequiresSelection,
  staleIntent,
  admissionEvidenceChanged,
  duplicateAdmission,
  timeoutBeforeExecution,
  executionOutcomeUnknown,
  observationMismatch,
  duplicateFirstSend,
}

String _sha256Json(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

T _enumByName<T extends Enum>(List<T> values, Object? name) {
  return values.singleWhere((value) => value.name == name);
}

/// Provider-resolved evidence for one human selection.
///
/// The policy deliberately does not normalize handles. The authoritative
/// resolver must supply [normalizedHandle], and the policy checks that exact
/// values for duplicates, self inclusion, staleness, matching, and dispatch.
/// This prevents a second, lossy normalization pass from silently changing the
/// recipient set.
class NewGroupRecipientEvidence {
  const NewGroupRecipientEvidence({
    required this.selectionId,
    required this.normalizedHandle,
    required this.isSelf,
    required this.iMessageCapability,
    required this.smsMmsCapability,
    required this.resolutionRevision,
    required this.observedAtEpochMilliseconds,
    required this.validUntilEpochMilliseconds,
  });

  final String selectionId;
  final String normalizedHandle;
  final bool isSelf;
  final NewGroupRecipientCapability iMessageCapability;
  final NewGroupRecipientCapability smsMmsCapability;
  final String resolutionRevision;
  final int observedAtEpochMilliseconds;
  final int validUntilEpochMilliseconds;

  NewGroupRecipientCapability capabilityFor(NewGroupRequestedService service) {
    return service == NewGroupRequestedService.iMessage ? iMessageCapability : smsMmsCapability;
  }

  bool isCurrentAt(int nowEpochMilliseconds) {
    return selectionId.isNotEmpty &&
        normalizedHandle.isNotEmpty &&
        resolutionRevision.isNotEmpty &&
        observedAtEpochMilliseconds <= nowEpochMilliseconds &&
        nowEpochMilliseconds <= validUntilEpochMilliseconds;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'selectionId': selectionId,
    'normalizedHandle': normalizedHandle,
    'isSelf': isSelf,
    'iMessageCapability': iMessageCapability.name,
    'smsMmsCapability': smsMmsCapability.name,
    'resolutionRevision': resolutionRevision,
    'observedAtEpochMilliseconds': observedAtEpochMilliseconds,
    'validUntilEpochMilliseconds': validUntilEpochMilliseconds,
  };

  factory NewGroupRecipientEvidence.fromJson(Map<String, dynamic> json) {
    return NewGroupRecipientEvidence(
      selectionId: json['selectionId'] as String,
      normalizedHandle: json['normalizedHandle'] as String,
      isSelf: json['isSelf'] as bool,
      iMessageCapability: _enumByName(NewGroupRecipientCapability.values, json['iMessageCapability']),
      smsMmsCapability: _enumByName(NewGroupRecipientCapability.values, json['smsMmsCapability']),
      resolutionRevision: json['resolutionRevision'] as String,
      observedAtEpochMilliseconds: (json['observedAtEpochMilliseconds'] as num).toInt(),
      validUntilEpochMilliseconds: (json['validUntilEpochMilliseconds'] as num).toInt(),
    );
  }
}

class NewGroupAttachmentIntent {
  const NewGroupAttachmentIntent({
    required this.intentId,
    required this.name,
    required this.size,
    required this.contentFingerprint,
  });

  final String intentId;
  final String name;
  final int size;
  final String contentFingerprint;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'intentId': intentId,
    'name': name,
    'size': size,
    'contentFingerprint': contentFingerprint,
  };

  factory NewGroupAttachmentIntent.fromJson(Map<String, dynamic> json) {
    return NewGroupAttachmentIntent(
      intentId: json['intentId'] as String,
      name: json['name'] as String,
      size: (json['size'] as num).toInt(),
      contentFingerprint: json['contentFingerprint'] as String,
    );
  }
}

/// Human intent before Apple has created a canonical physical chat identity.
///
/// No chat GUID or ROWID can be present here. The operation is instead bound
/// to the exact provider-normalized recipient set, requested service, expected
/// account/sender, draft, attachments, and a unique operation identity.
class NewLogicalConversationIntent {
  NewLogicalConversationIntent({
    required this.operationId,
    required List<NewGroupRecipientEvidence> recipients,
    required this.requestedService,
    required this.expectedAccountIdentity,
    required this.expectedSenderIdentity,
    required this.draftText,
    required List<NewGroupAttachmentIntent> attachments,
    required this.contentRevision,
    required this.createdAtEpochMilliseconds,
  }) : recipients = List<NewGroupRecipientEvidence>.unmodifiable(recipients),
       attachments = List<NewGroupAttachmentIntent>.unmodifiable(attachments);

  final String operationId;
  final List<NewGroupRecipientEvidence> recipients;
  final NewGroupRequestedService requestedService;
  final String expectedAccountIdentity;
  final String expectedSenderIdentity;
  final String draftText;
  final List<NewGroupAttachmentIntent> attachments;
  final int contentRevision;
  final int createdAtEpochMilliseconds;

  List<String> get normalizedRecipientSet {
    final result = recipients.map((recipient) => recipient.normalizedHandle).toList(growable: false)..sort();
    return List<String>.unmodifiable(result);
  }

  String get draftContentFingerprint => _sha256Json(<String, dynamic>{
    'text': draftText,
    'attachments': attachments.map((attachment) => attachment.toJson()).toList(growable: false),
  });

  /// Immutable execution payload identity, independent of local timestamps.
  ///
  /// The durable operation record binds [operationId] to this value. Reusing
  /// an operation ID with any different recipient, service, account, sender,
  /// draft, or attachment intent is rejected before execution.
  String get operationBindingFingerprint => _sha256Json(<String, dynamic>{
    'schema': newGroupIntentSchema,
    'normalizedRecipientSet': normalizedRecipientSet,
    'requestedService': requestedService.name,
    'expectedAccountIdentity': expectedAccountIdentity,
    'expectedSenderIdentity': expectedSenderIdentity,
    'draftContentFingerprint': draftContentFingerprint,
  });
  String get intentFingerprint => _sha256Json(<String, dynamic>{
    'schema': newGroupIntentSchema,
    'operationId': operationId,
    'normalizedRecipientSet': normalizedRecipientSet,
    'recipientResolutionRevisions':
        recipients
            .map(
              (recipient) => <String, String>{
                'normalizedHandle': recipient.normalizedHandle,
                'revision': recipient.resolutionRevision,
              },
            )
            .toList(growable: false)
          ..sort((a, b) => a['normalizedHandle']!.compareTo(b['normalizedHandle']!)),
    'requestedService': requestedService.name,
    'expectedAccountIdentity': expectedAccountIdentity,
    'expectedSenderIdentity': expectedSenderIdentity,
    'draftContentFingerprint': draftContentFingerprint,
    'contentRevision': contentRevision,
    'createdAtEpochMilliseconds': createdAtEpochMilliseconds,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': newGroupIntentSchema,
    'operationId': operationId,
    'recipients': recipients.map((recipient) => recipient.toJson()).toList(growable: false),
    'requestedService': requestedService.name,
    'expectedAccountIdentity': expectedAccountIdentity,
    'expectedSenderIdentity': expectedSenderIdentity,
    'draftText': draftText,
    'attachments': attachments.map((attachment) => attachment.toJson()).toList(growable: false),
    'contentRevision': contentRevision,
    'createdAtEpochMilliseconds': createdAtEpochMilliseconds,
  };

  factory NewLogicalConversationIntent.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != newGroupIntentSchema) {
      throw const FormatException('Unsupported new-group intent schema');
    }
    return NewLogicalConversationIntent(
      operationId: json['operationId'] as String,
      recipients: (json['recipients'] as List)
          .map((value) => NewGroupRecipientEvidence.fromJson((value as Map).cast<String, dynamic>()))
          .toList(growable: false),
      requestedService: _enumByName(NewGroupRequestedService.values, json['requestedService']),
      expectedAccountIdentity: json['expectedAccountIdentity'] as String,
      expectedSenderIdentity: json['expectedSenderIdentity'] as String,
      draftText: json['draftText'] as String,
      attachments: (json['attachments'] as List)
          .map((value) => NewGroupAttachmentIntent.fromJson((value as Map).cast<String, dynamic>()))
          .toList(growable: false),
      contentRevision: (json['contentRevision'] as num).toInt(),
      createdAtEpochMilliseconds: (json['createdAtEpochMilliseconds'] as num).toInt(),
    );
  }
}

/// Explicit provider evidence. A macOS version is intentionally not a
/// capability and therefore does not appear here.
class NewGroupProviderCapability {
  const NewGroupProviderCapability({
    required this.serverVersion,
    required this.evidenceRevision,
    required this.observedAtEpochMilliseconds,
    required this.validUntilEpochMilliseconds,
    required this.privateApiEnabled,
    required this.helperConnected,
    required this.helperCreateActionAttested,
    required this.iMessageGroupSupported,
    required this.smsMmsGroupSupported,
    required this.explicitAccountBinding,
    required this.explicitSenderBinding,
    required this.operationIdempotency,
    required this.appleObservation,
    required this.attachmentFirstSend,
  });

  final String serverVersion;
  final String evidenceRevision;
  final int observedAtEpochMilliseconds;
  final int validUntilEpochMilliseconds;
  final bool privateApiEnabled;
  final bool helperConnected;
  final bool helperCreateActionAttested;
  final bool iMessageGroupSupported;
  final bool smsMmsGroupSupported;
  final bool explicitAccountBinding;
  final bool explicitSenderBinding;
  final bool operationIdempotency;
  final bool appleObservation;
  final bool attachmentFirstSend;

  bool isCurrentAt(int nowEpochMilliseconds) {
    return evidenceRevision.isNotEmpty &&
        observedAtEpochMilliseconds <= nowEpochMilliseconds &&
        nowEpochMilliseconds <= validUntilEpochMilliseconds;
  }

  bool supports(NewGroupRequestedService service) {
    return service == NewGroupRequestedService.iMessage ? iMessageGroupSupported : smsMmsGroupSupported;
  }

  NewGroupProviderCapabilityState get capabilityState {
    if (!privateApiEnabled && !helperConnected) {
      return NewGroupProviderCapabilityState.appleScriptSingleOnly;
    }
    if (!privateApiEnabled || !helperConnected) {
      return NewGroupProviderCapabilityState.groupCreateUnavailable;
    }
    if (!helperCreateActionAttested) {
      return NewGroupProviderCapabilityState.privateRoutePresentUnattested;
    }
    final safeContract = explicitAccountBinding && explicitSenderBinding && operationIdempotency && appleObservation;
    if (!safeContract) {
      return NewGroupProviderCapabilityState.privateRouteAttestedUnsafeContract;
    }
    if (!iMessageGroupSupported && !smsMmsGroupSupported) {
      return NewGroupProviderCapabilityState.privateRouteSafeOffline;
    }
    return NewGroupProviderCapabilityState.privateRouteReadyForHumanAuthorizedExecution;
  }

  String get revision => _sha256Json(<String, dynamic>{
    'schema': newGroupCapabilitySchema,
    'serverVersion': serverVersion,
    'evidenceRevision': evidenceRevision,
    'observedAtEpochMilliseconds': observedAtEpochMilliseconds,
    'validUntilEpochMilliseconds': validUntilEpochMilliseconds,
    'privateApiEnabled': privateApiEnabled,
    'helperConnected': helperConnected,
    'helperCreateActionAttested': helperCreateActionAttested,
    'iMessageGroupSupported': iMessageGroupSupported,
    'smsMmsGroupSupported': smsMmsGroupSupported,
    'explicitAccountBinding': explicitAccountBinding,
    'explicitSenderBinding': explicitSenderBinding,
    'operationIdempotency': operationIdempotency,
    'appleObservation': appleObservation,
    'attachmentFirstSend': attachmentFirstSend,
  });
}

class NewGroupAccountProof {
  const NewGroupAccountProof({
    required this.accountIdentity,
    required this.senderIdentity,
    required this.evidenceRevision,
    required this.observedAtEpochMilliseconds,
    required this.validUntilEpochMilliseconds,
  });

  final String accountIdentity;
  final String senderIdentity;
  final String evidenceRevision;
  final int observedAtEpochMilliseconds;
  final int validUntilEpochMilliseconds;

  bool isCurrentAt(int nowEpochMilliseconds) {
    return accountIdentity.isNotEmpty &&
        senderIdentity.isNotEmpty &&
        evidenceRevision.isNotEmpty &&
        observedAtEpochMilliseconds <= nowEpochMilliseconds &&
        nowEpochMilliseconds <= validUntilEpochMilliseconds;
  }
}

/// Read-only Apple-created conversation evidence. This object is never used to
/// synthesize a physical chat and carries no write operation.
class ExistingPhysicalGroupEvidence {
  ExistingPhysicalGroupEvidence({
    required this.physicalIdentity,
    required List<String> normalizedRecipients,
    required this.service,
    required this.accountIdentity,
    required this.isHistorical,
  }) : normalizedRecipients = List<String>.unmodifiable(List<String>.of(normalizedRecipients)..sort());

  final String physicalIdentity;
  final List<String> normalizedRecipients;
  final NewGroupRequestedService service;
  final String accountIdentity;
  final bool isHistorical;

  bool exactlyMatches(NewLogicalConversationIntent intent) {
    if (service != intent.requestedService || accountIdentity != intent.expectedAccountIdentity) return false;
    final expected = intent.normalizedRecipientSet;
    if (normalizedRecipients.length != expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (normalizedRecipients[i] != expected[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toEvidenceJson() => <String, dynamic>{
    'physicalIdentity': physicalIdentity,
    'normalizedRecipients': normalizedRecipients,
    'service': service.name,
    'accountIdentity': accountIdentity,
    'isHistorical': isHistorical,
  };
}

class NewGroupExistingDecision {
  NewGroupExistingDecision({required this.state, required List<String> matchingPhysicalIdentities})
    : matchingPhysicalIdentities = List<String>.unmodifiable(matchingPhysicalIdentities);

  final NewGroupExistingMatchState state;
  final List<String> matchingPhysicalIdentities;

  bool get requiresSelection => state != NewGroupExistingMatchState.none;

  static NewGroupExistingDecision evaluate(
    NewLogicalConversationIntent intent,
    Iterable<ExistingPhysicalGroupEvidence> candidates,
  ) {
    final exact = candidates.where((candidate) => candidate.exactlyMatches(intent)).toList(growable: false);
    if (exact.isEmpty) {
      return NewGroupExistingDecision(state: NewGroupExistingMatchState.none, matchingPhysicalIdentities: const []);
    }
    if (exact.length > 1) {
      return NewGroupExistingDecision(
        state: NewGroupExistingMatchState.multipleExact,
        matchingPhysicalIdentities: exact.map((candidate) => candidate.physicalIdentity).toList(growable: false),
      );
    }
    return NewGroupExistingDecision(
      state: exact.single.isHistorical
          ? NewGroupExistingMatchState.exactHistorical
          : NewGroupExistingMatchState.exactCurrent,
      matchingPhysicalIdentities: <String>[exact.single.physicalIdentity],
    );
  }
}

class NewGroupPreflightResult {
  const NewGroupPreflightResult({
    required this.state,
    required this.reason,
    required this.userMessage,
    required this.evidenceRevision,
  });

  final NewGroupPreflightState state;
  final NewGroupFailureReason reason;
  final String userMessage;
  final String evidenceRevision;

  bool get isReady => state == NewGroupPreflightState.ready;
}

class NewGroupPreflight {
  const NewGroupPreflight._();

  static NewGroupPreflightResult evaluate({
    required NewLogicalConversationIntent intent,
    required NewGroupProviderCapability provider,
    required NewGroupAccountProof? accountProof,
    required Iterable<ExistingPhysicalGroupEvidence> existingGroups,
    required int nowEpochMilliseconds,
  }) {
    final existingGroupList = existingGroups.toList(growable: false);
    final evidenceRevision = _sha256Json(<String, dynamic>{
      'intentFingerprint': intent.intentFingerprint,
      'recipientEvidence': intent.recipients.map((recipient) => recipient.toJson()).toList(growable: false)
        ..sort((a, b) => (a['normalizedHandle'] as String).compareTo(b['normalizedHandle'] as String)),
      'providerRevision': provider.revision,
      'accountProof': accountProof == null
          ? null
          : <String, dynamic>{
              'accountIdentity': accountProof.accountIdentity,
              'senderIdentity': accountProof.senderIdentity,
              'evidenceRevision': accountProof.evidenceRevision,
              'observedAtEpochMilliseconds': accountProof.observedAtEpochMilliseconds,
              'validUntilEpochMilliseconds': accountProof.validUntilEpochMilliseconds,
            },
      'existingGroups': existingGroupList.map((group) => group.toEvidenceJson()).toList(growable: false)
        ..sort((a, b) => (a['physicalIdentity'] as String).compareTo(b['physicalIdentity'] as String)),
    });
    NewGroupPreflightResult blocked(NewGroupFailureReason reason, String message) => NewGroupPreflightResult(
      state: NewGroupPreflightState.blocked,
      reason: reason,
      userMessage: message,
      evidenceRevision: evidenceRevision,
    );

    if (intent.operationId.trim().isEmpty) {
      return blocked(
        NewGroupFailureReason.invalidOperationIdentity,
        'Group creation unavailable — operation identity missing',
      );
    }
    if (intent.recipients.length < 2) {
      return blocked(NewGroupFailureReason.tooFewRecipients, 'Select at least two recipients for a group');
    }
    final normalized = intent.normalizedRecipientSet;
    if (normalized.toSet().length != normalized.length) {
      return blocked(
        NewGroupFailureReason.duplicateRecipient,
        'Duplicate recipient detected — review the exact recipient set',
      );
    }
    if (intent.recipients.any((recipient) => recipient.isSelf)) {
      return blocked(NewGroupFailureReason.selfRecipient, 'Your own sender identity is already part of the group');
    }
    if (intent.recipients.any((recipient) => !recipient.isCurrentAt(nowEpochMilliseconds))) {
      return blocked(
        NewGroupFailureReason.staleRecipientResolution,
        'Recipient status changed — validate the recipient set again',
      );
    }
    final capabilities = intent.recipients.map((recipient) => recipient.capabilityFor(intent.requestedService));
    if (capabilities.any((capability) => capability == NewGroupRecipientCapability.unavailable)) {
      return blocked(
        NewGroupFailureReason.recipientUnavailable,
        intent.requestedService == NewGroupRequestedService.iMessage
            ? 'Recipient unavailable for iMessage'
            : 'Recipient unavailable for SMS/MMS',
      );
    }
    if (capabilities.any((capability) => capability == NewGroupRecipientCapability.unknown)) {
      return blocked(
        NewGroupFailureReason.recipientCapabilityUnknown,
        'Recipient service capability unknown — no fallback was applied',
      );
    }
    if (intent.draftText.trim().isEmpty && intent.attachments.isEmpty) {
      return blocked(
        NewGroupFailureReason.emptyFirstSend,
        'A first message or attachment is required to create the group',
      );
    }
    if (!provider.isCurrentAt(nowEpochMilliseconds) || !provider.supports(intent.requestedService)) {
      return blocked(
        NewGroupFailureReason.serviceUnsupported,
        'Group creation unavailable — requested service is not proven',
      );
    }
    if (!provider.privateApiEnabled) {
      return blocked(
        NewGroupFailureReason.privateApiUnavailable,
        'Group creation unavailable — Private API capability missing',
      );
    }
    if (!provider.helperConnected) {
      return blocked(NewGroupFailureReason.helperUnavailable, 'Group creation unavailable — helper capability missing');
    }
    if (!provider.helperCreateActionAttested) {
      return blocked(
        NewGroupFailureReason.helperCreateActionUnattested,
        'Group creation unavailable — helper create capability not verified',
      );
    }
    if (accountProof == null || !accountProof.isCurrentAt(nowEpochMilliseconds)) {
      return blocked(
        NewGroupFailureReason.accountProofMissing,
        'Group creation unavailable — sender account not proven',
      );
    }
    if (accountProof.accountIdentity != intent.expectedAccountIdentity) {
      return blocked(
        NewGroupFailureReason.accountMismatch,
        'Group creation blocked — account does not match the draft',
      );
    }
    if (accountProof.senderIdentity != intent.expectedSenderIdentity) {
      return blocked(NewGroupFailureReason.senderMismatch, 'Group creation blocked — sender does not match the draft');
    }
    if (!provider.explicitAccountBinding) {
      return blocked(
        NewGroupFailureReason.accountBindingUnsupported,
        'Group creation unavailable — account binding is not supported',
      );
    }
    if (!provider.explicitSenderBinding) {
      return blocked(
        NewGroupFailureReason.senderBindingUnsupported,
        'Group creation unavailable — sender binding is not supported',
      );
    }
    if (!provider.operationIdempotency) {
      return blocked(
        NewGroupFailureReason.operationIdempotencyUnsupported,
        'Group creation unavailable — safe replay protection is not supported',
      );
    }
    if (!provider.appleObservation) {
      return blocked(
        NewGroupFailureReason.appleObservationUnsupported,
        'Group creation unavailable — Apple result observation is not supported',
      );
    }
    if (intent.attachments.isNotEmpty && !provider.attachmentFirstSend) {
      return blocked(
        NewGroupFailureReason.attachmentFirstSendUnsupported,
        'Group creation unavailable — first-send attachments are not supported',
      );
    }

    final existing = NewGroupExistingDecision.evaluate(intent, existingGroupList);
    if (existing.requiresSelection) {
      return NewGroupPreflightResult(
        state: NewGroupPreflightState.existingSelectionRequired,
        reason: NewGroupFailureReason.existingGroupRequiresSelection,
        userMessage: 'Existing matching group requires selection',
        evidenceRevision: evidenceRevision,
      );
    }

    return NewGroupPreflightResult(
      state: NewGroupPreflightState.ready,
      reason: NewGroupFailureReason.none,
      userMessage: intent.requestedService == NewGroupRequestedService.iMessage
          ? 'Group iMessage ready'
          : 'Group SMS/MMS ready',
      evidenceRevision: evidenceRevision,
    );
  }
}

class NewGroupAppleObservation {
  NewGroupAppleObservation({
    required this.chatGuid,
    required this.chatRowId,
    required this.firstMessageGuid,
    required List<String> normalizedRecipients,
    required this.service,
    required this.accountIdentity,
    required this.senderIdentity,
    required this.draftContentFingerprint,
    required this.matchingFirstMessageCount,
    required this.isFromMe,
    required this.isTerminallySent,
  }) : normalizedRecipients = List<String>.unmodifiable(List<String>.of(normalizedRecipients)..sort());

  final String chatGuid;
  final int chatRowId;
  final String firstMessageGuid;
  final List<String> normalizedRecipients;
  final NewGroupRequestedService service;
  final String accountIdentity;
  final String senderIdentity;
  final String draftContentFingerprint;
  final int matchingFirstMessageCount;
  final bool isFromMe;
  final bool isTerminallySent;

  bool exactlyMatches(NewLogicalConversationIntent intent) {
    if (chatGuid.isEmpty ||
        chatRowId <= 0 ||
        firstMessageGuid.isEmpty ||
        service != intent.requestedService ||
        accountIdentity != intent.expectedAccountIdentity ||
        senderIdentity != intent.expectedSenderIdentity ||
        draftContentFingerprint != intent.draftContentFingerprint ||
        !isFromMe ||
        !isTerminallySent) {
      return false;
    }
    final expected = intent.normalizedRecipientSet;
    if (normalizedRecipients.length != expected.length || normalizedRecipients.toSet().length != expected.length) {
      return false;
    }
    for (var i = 0; i < expected.length; i++) {
      if (normalizedRecipients[i] != expected[i]) return false;
    }
    return true;
  }
}

class NewGroupExecutionRecord {
  const NewGroupExecutionRecord({
    required this.operationId,
    required this.intentFingerprint,
    required this.providerCapabilityRevision,
    required this.admissionEvidenceRevision,
    required this.state,
    required this.reason,
    required this.admittedAtEpochMilliseconds,
    required this.updatedAtEpochMilliseconds,
    required this.executionAttemptCount,
    this.appleChatGuid,
    this.appleChatRowId,
    this.firstMessageGuid,
  });

  final String operationId;
  final String intentFingerprint;
  final String providerCapabilityRevision;
  final String admissionEvidenceRevision;
  final NewGroupOperationState state;
  final NewGroupFailureReason reason;
  final int admittedAtEpochMilliseconds;
  final int updatedAtEpochMilliseconds;
  final int executionAttemptCount;
  final String? appleChatGuid;
  final int? appleChatRowId;
  final String? firstMessageGuid;

  String get userMessage {
    if (state == NewGroupOperationState.outcomeAmbiguous) {
      return 'Group creation outcome unknown — do not retry automatically';
    }
    if (state == NewGroupOperationState.succeeded) return 'Group creation verified';
    if (state == NewGroupOperationState.executionStarted) return 'Group creation is in progress';
    if (state == NewGroupOperationState.blockedBeforeExecution) return 'Group creation stopped before execution';
    return 'Group creation admitted';
  }

  NewGroupExecutionRecord copyWith({
    NewGroupOperationState? state,
    NewGroupFailureReason? reason,
    int? updatedAtEpochMilliseconds,
    int? executionAttemptCount,
    String? appleChatGuid,
    int? appleChatRowId,
    String? firstMessageGuid,
  }) {
    return NewGroupExecutionRecord(
      operationId: operationId,
      intentFingerprint: intentFingerprint,
      providerCapabilityRevision: providerCapabilityRevision,
      admissionEvidenceRevision: admissionEvidenceRevision,
      state: state ?? this.state,
      reason: reason ?? this.reason,
      admittedAtEpochMilliseconds: admittedAtEpochMilliseconds,
      updatedAtEpochMilliseconds: updatedAtEpochMilliseconds ?? this.updatedAtEpochMilliseconds,
      executionAttemptCount: executionAttemptCount ?? this.executionAttemptCount,
      appleChatGuid: appleChatGuid ?? this.appleChatGuid,
      appleChatRowId: appleChatRowId ?? this.appleChatRowId,
      firstMessageGuid: firstMessageGuid ?? this.firstMessageGuid,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'operationId': operationId,
    'intentFingerprint': intentFingerprint,
    'providerCapabilityRevision': providerCapabilityRevision,
    'admissionEvidenceRevision': admissionEvidenceRevision,
    'state': state.name,
    'reason': reason.name,
    'admittedAtEpochMilliseconds': admittedAtEpochMilliseconds,
    'updatedAtEpochMilliseconds': updatedAtEpochMilliseconds,
    'executionAttemptCount': executionAttemptCount,
    if (appleChatGuid != null) 'appleChatGuid': appleChatGuid,
    if (appleChatRowId != null) 'appleChatRowId': appleChatRowId,
    if (firstMessageGuid != null) 'firstMessageGuid': firstMessageGuid,
  };

  factory NewGroupExecutionRecord.fromJson(Map<String, dynamic> json) {
    return NewGroupExecutionRecord(
      operationId: json['operationId'] as String,
      intentFingerprint: json['intentFingerprint'] as String,
      providerCapabilityRevision: json['providerCapabilityRevision'] as String,
      admissionEvidenceRevision: json['admissionEvidenceRevision'] as String,
      state: _enumByName(NewGroupOperationState.values, json['state']),
      reason: _enumByName(NewGroupFailureReason.values, json['reason']),
      admittedAtEpochMilliseconds: (json['admittedAtEpochMilliseconds'] as num).toInt(),
      updatedAtEpochMilliseconds: (json['updatedAtEpochMilliseconds'] as num).toInt(),
      executionAttemptCount: (json['executionAttemptCount'] as num).toInt(),
      appleChatGuid: json['appleChatGuid'] as String?,
      appleChatRowId: (json['appleChatRowId'] as num?)?.toInt(),
      firstMessageGuid: json['firstMessageGuid'] as String?,
    );
  }
}

class NewGroupAdmissionResult {
  const NewGroupAdmissionResult({
    required this.record,
    required this.created,
    required this.executionMayStart,
    required this.reason,
  });

  final NewGroupExecutionRecord record;
  final bool created;
  final bool executionMayStart;
  final NewGroupFailureReason reason;
}

class NewGroupExecutionReservation {
  const NewGroupExecutionReservation({required this.record, required this.dispatchGranted});

  final NewGroupExecutionRecord record;
  final bool dispatchGranted;
}

/// Serializable admission state. The integration must atomically persist the
/// newly admitted or execution-started state before making a transport call.
/// The current BlueBubbles endpoint cannot honor the operation identity, so
/// production execution must remain capability-blocked.
class NewGroupOperationLedger {
  NewGroupOperationLedger._(this._records);

  factory NewGroupOperationLedger.empty() => NewGroupOperationLedger._(<String, NewGroupExecutionRecord>{});

  factory NewGroupOperationLedger.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != newGroupOperationSchema) {
      throw const FormatException('Unsupported new-group operation schema');
    }
    final records = <String, NewGroupExecutionRecord>{};
    for (final value in json['records'] as List) {
      final record = NewGroupExecutionRecord.fromJson((value as Map).cast<String, dynamic>());
      if (records.containsKey(record.operationId)) {
        throw const FormatException('Duplicate new-group operation identity');
      }
      records[record.operationId] = record;
    }
    return NewGroupOperationLedger._(records);
  }

  final Map<String, NewGroupExecutionRecord> _records;

  List<NewGroupExecutionRecord> get records => List<NewGroupExecutionRecord>.unmodifiable(_records.values);

  NewGroupExecutionRecord? recordFor(String operationId) => _records[operationId];

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': newGroupOperationSchema,
    'records': _records.values.map((record) => record.toJson()).toList(growable: false),
  };

  NewGroupAdmissionResult admit({
    required NewLogicalConversationIntent intent,
    required NewGroupProviderCapability provider,
    required NewGroupPreflightResult preflight,
    required int nowEpochMilliseconds,
  }) {
    final existing = _records[intent.operationId];
    if (existing != null) {
      final stale = existing.intentFingerprint != intent.intentFingerprint;
      return NewGroupAdmissionResult(
        record: existing,
        created: false,
        executionMayStart: false,
        reason: stale ? NewGroupFailureReason.staleIntent : NewGroupFailureReason.duplicateAdmission,
      );
    }
    if (!preflight.isReady) {
      final blocked = NewGroupExecutionRecord(
        operationId: intent.operationId,
        intentFingerprint: intent.intentFingerprint,
        providerCapabilityRevision: provider.revision,
        admissionEvidenceRevision: preflight.evidenceRevision,
        state: NewGroupOperationState.blockedBeforeExecution,
        reason: preflight.reason,
        admittedAtEpochMilliseconds: nowEpochMilliseconds,
        updatedAtEpochMilliseconds: nowEpochMilliseconds,
        executionAttemptCount: 0,
      );
      return NewGroupAdmissionResult(
        record: blocked,
        created: false,
        executionMayStart: false,
        reason: preflight.reason,
      );
    }
    final record = NewGroupExecutionRecord(
      operationId: intent.operationId,
      intentFingerprint: intent.intentFingerprint,
      providerCapabilityRevision: provider.revision,
      admissionEvidenceRevision: preflight.evidenceRevision,
      state: NewGroupOperationState.admitted,
      reason: NewGroupFailureReason.none,
      admittedAtEpochMilliseconds: nowEpochMilliseconds,
      updatedAtEpochMilliseconds: nowEpochMilliseconds,
      executionAttemptCount: 0,
    );
    _records[intent.operationId] = record;
    return NewGroupAdmissionResult(
      record: record,
      created: true,
      executionMayStart: true,
      reason: NewGroupFailureReason.none,
    );
  }

  NewGroupExecutionReservation reserveExecution({
    required NewLogicalConversationIntent intent,
    required String currentProviderCapabilityRevision,
    required NewGroupPreflightResult currentPreflight,
    required int nowEpochMilliseconds,
  }) {
    final record = _records[intent.operationId];
    if (record == null) {
      return NewGroupExecutionReservation(
        record: NewGroupExecutionRecord(
          operationId: intent.operationId,
          intentFingerprint: intent.intentFingerprint,
          providerCapabilityRevision: currentProviderCapabilityRevision,
          admissionEvidenceRevision: currentPreflight.evidenceRevision,
          state: NewGroupOperationState.blockedBeforeExecution,
          reason: NewGroupFailureReason.staleIntent,
          admittedAtEpochMilliseconds: nowEpochMilliseconds,
          updatedAtEpochMilliseconds: nowEpochMilliseconds,
          executionAttemptCount: 0,
        ),
        dispatchGranted: false,
      );
    }
    if (record.state != NewGroupOperationState.admitted) {
      return NewGroupExecutionReservation(record: record, dispatchGranted: false);
    }
    final staleIntent = record.intentFingerprint != intent.intentFingerprint;
    final evidenceChanged =
        !currentPreflight.isReady ||
        record.providerCapabilityRevision != currentProviderCapabilityRevision ||
        record.admissionEvidenceRevision != currentPreflight.evidenceRevision;
    if (staleIntent || evidenceChanged) {
      final blocked = record.copyWith(
        state: NewGroupOperationState.blockedBeforeExecution,
        reason: staleIntent ? NewGroupFailureReason.staleIntent : NewGroupFailureReason.admissionEvidenceChanged,
        updatedAtEpochMilliseconds: nowEpochMilliseconds,
      );
      _records[intent.operationId] = blocked;
      return NewGroupExecutionReservation(record: blocked, dispatchGranted: false);
    }
    final executing = record.copyWith(
      state: NewGroupOperationState.executionStarted,
      updatedAtEpochMilliseconds: nowEpochMilliseconds,
      executionAttemptCount: 1,
    );
    _records[intent.operationId] = executing;
    return NewGroupExecutionReservation(record: executing, dispatchGranted: true);
  }

  bool markTimeoutBeforeExecution(String operationId, int nowEpochMilliseconds) {
    final record = _records[operationId];
    if (record == null || record.state != NewGroupOperationState.admitted) return false;
    _records[operationId] = record.copyWith(
      state: NewGroupOperationState.blockedBeforeExecution,
      reason: NewGroupFailureReason.timeoutBeforeExecution,
      updatedAtEpochMilliseconds: nowEpochMilliseconds,
    );
    return true;
  }

  bool markOutcomeAmbiguous(String operationId, int nowEpochMilliseconds) {
    final record = _records[operationId];
    if (record == null || record.state != NewGroupOperationState.executionStarted) return false;
    _records[operationId] = record.copyWith(
      state: NewGroupOperationState.outcomeAmbiguous,
      reason: NewGroupFailureReason.executionOutcomeUnknown,
      updatedAtEpochMilliseconds: nowEpochMilliseconds,
    );
    return true;
  }

  int recoverInterruptedExecutions(int nowEpochMilliseconds) {
    var changed = 0;
    for (final entry in _records.entries.toList(growable: false)) {
      if (entry.value.state != NewGroupOperationState.executionStarted) continue;
      _records[entry.key] = entry.value.copyWith(
        state: NewGroupOperationState.outcomeAmbiguous,
        reason: NewGroupFailureReason.executionOutcomeUnknown,
        updatedAtEpochMilliseconds: nowEpochMilliseconds,
      );
      changed += 1;
    }
    return changed;
  }

  bool confirmAppleObservation({
    required NewLogicalConversationIntent intent,
    required NewGroupAppleObservation observation,
    required int nowEpochMilliseconds,
  }) {
    final record = _records[intent.operationId];
    if (record == null ||
        (record.state != NewGroupOperationState.executionStarted &&
            record.state != NewGroupOperationState.outcomeAmbiguous)) {
      return false;
    }
    if (observation.matchingFirstMessageCount != 1) {
      _records[intent.operationId] = record.copyWith(
        state: NewGroupOperationState.outcomeAmbiguous,
        reason: NewGroupFailureReason.duplicateFirstSend,
        updatedAtEpochMilliseconds: nowEpochMilliseconds,
      );
      return false;
    }
    if (record.intentFingerprint != intent.intentFingerprint || !observation.exactlyMatches(intent)) {
      _records[intent.operationId] = record.copyWith(
        state: NewGroupOperationState.outcomeAmbiguous,
        reason: NewGroupFailureReason.observationMismatch,
        updatedAtEpochMilliseconds: nowEpochMilliseconds,
      );
      return false;
    }
    _records[intent.operationId] = record.copyWith(
      state: NewGroupOperationState.succeeded,
      reason: NewGroupFailureReason.none,
      updatedAtEpochMilliseconds: nowEpochMilliseconds,
      appleChatGuid: observation.chatGuid,
      appleChatRowId: observation.chatRowId,
      firstMessageGuid: observation.firstMessageGuid,
    );
    return true;
  }
}
