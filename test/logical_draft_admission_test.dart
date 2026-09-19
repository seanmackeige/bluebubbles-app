import 'dart:convert';

import 'package:bluebubbles/services/backend/settings/actions/shared_preferences_messaging_actions.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _logicalId = 'comcast-node-updates';
const _sourceChatRowId = 2156;
const _sourceChatGuid = 'SMS;-;comcast-node-updates-current';

const _attachment = LogicalAttachmentIntent(
  intentId: 'attachment-intent-1',
  name: 'diagram.png',
  size: 4096,
  isRestorable: true,
  path: '/safe/staging/diagram.png',
  mimeType: 'image/png',
);

const _ephemeralAttachment = LogicalAttachmentIntent(
  intentId: 'attachment-intent-2',
  name: 'clipboard.png',
  size: 1024,
  isRestorable: false,
  mimeType: 'image/png',
);

const _reply = LogicalReplyIntent(
  messageGuid: 'reply-source-message-guid',
  relationshipTargetGuid: 'p:2/reply-source-message-guid',
  sourceChatRowId: 2027,
  sourceChatGuid: 'iMessage;-;comcast-node-updates-history',
  part: 2,
);

LogicalAuthorityRevision _revision({
  String certificate = 'certificate-v1',
  String authority = 'authority-v1',
  int epoch = 101,
}) {
  return LogicalAuthorityRevision(certificateRevision: certificate, authorityRevision: authority, epoch: epoch);
}

LogicalDraft _draft({
  String logicalId = _logicalId,
  LogicalAuthorityRevision? revision,
  String text = 'Draft text that belongs to the human conversation',
  String subject = 'Logical subject',
  List<LogicalAttachmentIntent> attachments = const <LogicalAttachmentIntent>[_attachment, _ephemeralAttachment],
  LogicalReplyIntent? reply = _reply,
}) {
  return LogicalDraft.create(
    logicalId: logicalId,
    nowEpochMilliseconds: 1000,
    observedRevision: revision ?? _revision(),
  ).mergeUserIntent(
    text: text,
    subject: subject,
    attachments: attachments,
    reply: reply,
    effectId: 'echo',
    updatedAtEpochMilliseconds: 1100,
    observedRevision: revision ?? _revision(),
  );
}

LogicalSendAdmissionReceipt _receipt(
  String suffix, {
  String? actionId,
  int targetSourceChatRowId = _sourceChatRowId,
  String targetSourceChatGuid = _sourceChatGuid,
  LogicalAuthorityRevision? revision,
}) {
  final observed = revision ?? _revision();
  return LogicalSendAdmissionReceipt(
    admissionId: 'admission-$suffix',
    actionId: actionId ?? 'action-$suffix',
    logicalId: _logicalId,
    draftContentRevision: 2,
    certificateRevision: observed.certificateRevision,
    authorityRevision: observed.authorityRevision,
    authorityEpoch: observed.epoch,
    targetSourceChatRowId: targetSourceChatRowId,
    targetSourceChatGuid: targetSourceChatGuid,
    transportTempGuid: 'temp-$suffix',
    payloadFingerprint: sha256.convert(utf8.encode('payload-$suffix')).toString(),
    providerContextFingerprint: sha256.convert(utf8.encode('provider-$suffix')).toString(),
    committedAtEpochMilliseconds: 2000,
  );
}

Map<String, dynamic> _jsonRoundTrip(Map<String, dynamic> source) {
  return (jsonDecode(jsonEncode(source)) as Map).cast<String, dynamic>();
}

List<Map<String, dynamic>> _entriesRoundTrip(List<Map<String, dynamic>> entries) {
  return (jsonDecode(jsonEncode(entries)) as List)
      .map((entry) => (entry as Map).cast<String, dynamic>())
      .toList(growable: false);
}

LogicalOperationState? _stateOf(LogicalAdmissionLedger ledger, String admissionId) {
  final matches = ledger.entries.where((entry) => entry['admissionId'] == admissionId).toList(growable: false);
  if (matches.length != 1) return null;
  final name = matches.single['operationState'];
  return LogicalOperationState.values.where((state) => state.name == name).firstOrNull;
}

typedef _InjectionOutcome = ({
  int admissionCount,
  int attachmentStageCount,
  int repositoryCallCount,
  int dispatchCount,
  LogicalOperationState? operationState,
});

class _DispatchHarness {
  _DispatchHarness(this.receipt) : ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);

  final LogicalSendAdmissionReceipt receipt;
  late LogicalAdmissionLedger ledger;
  int dispatchCount = 0;

  bool commit() => ledger.commitBatch(<LogicalSendAdmissionReceipt>[receipt], <String>['initial:${receipt.actionId}']);

  bool dispatch({bool outcomeUnknown = false}) {
    if (!ledger.transition(
      receipt.admissionId,
      LogicalOperationState.admitted,
      LogicalOperationState.dispatchReserved,
    )) {
      return false;
    }
    dispatchCount += 1;
    return ledger.transition(
      receipt.admissionId,
      LogicalOperationState.dispatchReserved,
      outcomeUnknown ? LogicalOperationState.outcomeUnknown : LogicalOperationState.confirmed,
    );
  }

  void recreate() {
    ledger = LogicalAdmissionLedger.fromEntries(_entriesRoundTrip(ledger.entries));
  }
}

enum _InjectionPoint {
  beforeTap('before tap'),
  duringAdmission('during admission'),
  afterAdmissionBeforeRepositoryCall('after admission before repository call'),
  duringAttachmentStaging('during attachment staging'),
  duringAsyncSend('during async send'),
  duringUiLifecycleRecreation('during UI lifecycle recreation');

  const _InjectionPoint(this.label);

  final String label;
}

_InjectionOutcome _runInjection(_InjectionPoint point) {
  final tracker = LogicalAuthorityRevisionTracker(seedEpoch: 100);
  final admittedRevision = tracker.observe(certificateRevision: 'certificate-v1', authorityRevision: 'authority-v1');
  final draft = _draft(revision: admittedRevision);
  final harness = _DispatchHarness(_receipt('injection', actionId: draft.actionId, revision: admittedRevision));
  var admissionCount = 0;
  var attachmentStageCount = 0;
  var repositoryCallCount = 0;

  bool attemptAtomicAdmission({bool invalidateBeforeCommit = false}) {
    admissionCount += 1;
    final checkedRevision = tracker.current;
    if (checkedRevision == null || !checkedRevision.matchesDraft(draft)) return false;
    if (invalidateBeforeCommit) tracker.invalidate(point.label);
    final commitRevision = tracker.current;
    if (commitRevision == null ||
        commitRevision.certificateRevision != checkedRevision.certificateRevision ||
        commitRevision.authorityRevision != checkedRevision.authorityRevision ||
        commitRevision.epoch != checkedRevision.epoch ||
        !commitRevision.matchesDraft(draft)) {
      return false;
    }
    return harness.commit();
  }

  _InjectionOutcome outcome() => (
    admissionCount: admissionCount,
    attachmentStageCount: attachmentStageCount,
    repositoryCallCount: repositoryCallCount,
    dispatchCount: harness.dispatchCount,
    operationState: _stateOf(harness.ledger, harness.receipt.admissionId),
  );

  void expectCommittedBindingFrozen() {
    expect(harness.receipt.certificateRevision, admittedRevision.certificateRevision);
    expect(harness.receipt.authorityRevision, admittedRevision.authorityRevision);
    expect(harness.receipt.authorityEpoch, admittedRevision.epoch);
    expect(tracker.current!.authorityRevision, isNot(harness.receipt.authorityRevision));
  }

  bool dispatchAtCurrentAuthority() {
    final current = tracker.current;
    final stillCurrent =
        current != null &&
        current.certificateRevision == harness.receipt.certificateRevision &&
        current.authorityRevision == harness.receipt.authorityRevision &&
        current.epoch == harness.receipt.authorityEpoch;
    if (!stillCurrent) {
      expect(harness.ledger.rollbackAdmittedBatch(<String>[harness.receipt.admissionId]), isTrue);
      return false;
    }
    repositoryCallCount += 1;
    return harness.dispatch();
  }

  if (point == _InjectionPoint.beforeTap) {
    final changed = tracker.invalidate(point.label);
    expect(changed.matchesDraft(draft), isFalse);
    expect(attemptAtomicAdmission(), isFalse);
    return outcome();
  }

  if (point == _InjectionPoint.duringAdmission) {
    expect(attemptAtomicAdmission(invalidateBeforeCommit: true), isFalse);
    expect(tracker.current!.matchesDraft(draft), isFalse);
    expect(harness.ledger.entries, isEmpty);
    return outcome();
  }

  expect(attemptAtomicAdmission(), isTrue);

  switch (point) {
    case _InjectionPoint.afterAdmissionBeforeRepositoryCall:
      tracker.invalidate(point.label);
      expectCommittedBindingFrozen();
      expect(dispatchAtCurrentAuthority(), isFalse);
      return outcome();
    case _InjectionPoint.duringAttachmentStaging:
      attachmentStageCount += 1;
      tracker.invalidate(point.label);
      expectCommittedBindingFrozen();
      expect(dispatchAtCurrentAuthority(), isFalse);
      return outcome();
    case _InjectionPoint.duringAsyncSend:
      repositoryCallCount += 1;
      expect(
        harness.ledger.transition(
          harness.receipt.admissionId,
          LogicalOperationState.admitted,
          LogicalOperationState.dispatchReserved,
        ),
        isTrue,
      );
      harness.dispatchCount += 1;
      tracker.invalidate(point.label);
      expectCommittedBindingFrozen();
      expect(
        harness.ledger.transition(
          harness.receipt.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.outcomeUnknown,
        ),
        isTrue,
      );
      return outcome();
    case _InjectionPoint.duringUiLifecycleRecreation:
      repositoryCallCount += 1;
      expect(
        harness.ledger.transition(
          harness.receipt.admissionId,
          LogicalOperationState.admitted,
          LogicalOperationState.dispatchReserved,
        ),
        isTrue,
      );
      harness.dispatchCount += 1;
      harness.recreate();
      tracker.invalidate(point.label);
      expectCommittedBindingFrozen();
      expect(harness.dispatch(), isFalse);
      expect(
        harness.ledger.transition(
          harness.receipt.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.outcomeUnknown,
        ),
        isTrue,
      );
      return outcome();
    case _InjectionPoint.beforeTap:
    case _InjectionPoint.duringAdmission:
      throw StateError('Handled before commitment');
  }
}

void main() {
  group('logical draft identity and survival', () {
    test('draft belongs to logical identity and contains no physical execution binding', () {
      final draft = _draft();
      final encoded = draft.toJson();

      expect(draft.logicalId, _logicalId);
      expect(encoded['logicalId'], _logicalId);
      for (final physicalBinding in <String>[
        'physicalChatGuid',
        'physicalChatRowId',
        'targetSourceChatGuid',
        'targetSourceChatRowId',
      ]) {
        expect(encoded.containsKey(physicalBinding), isFalse);
      }
    });

    test('authority revision re-arms the same human intent without changing its action identity', () {
      final original = _draft();
      final changed = _revision(authority: 'authority-v2', epoch: 102);
      final rearmed = original.rearm(changed, updatedAtEpochMilliseconds: 1200);

      expect(changed.matchesDraft(original), isFalse);
      expect(changed.matchesDraft(rearmed), isTrue);
      expect(rearmed.logicalId, original.logicalId);
      expect(rearmed.contentRevision, original.contentRevision);
      expect(rearmed.contentFingerprint, original.contentFingerprint);
      expect(rearmed.actionId, original.actionId);
      expect(rearmed.text, original.text);
      expect(rearmed.attachments.map((item) => item.intentId), original.attachments.map((item) => item.intentId));
      expect(rearmed.reply?.relationshipTargetGuid, original.reply?.relationshipTargetGuid);
      expect(rearmed.compositionCertificateRevision, original.compositionCertificateRevision);
      expect(rearmed.compositionAuthorityRevision, original.compositionAuthorityRevision);
      expect(rearmed.compositionAuthorityEpoch, original.compositionAuthorityEpoch);
    });

    test('membership certificate revision re-arms and preserves the draft', () {
      final original = _draft();
      final changed = _revision(certificate: 'certificate-v2', epoch: 102);
      final rearmed = original.rearm(changed, updatedAtEpochMilliseconds: 1200);
      final blocked = LogicalSendAdmissionResult.blocked(
        LogicalSendAdmissionState.authorityChanged,
        'SEND_BLOCKED_MEMBERSHIP_CERTIFICATE_CHANGED',
        rearmedDraft: rearmed,
      );

      expect(blocked.isReady, isFalse);
      expect(blocked.rearmedDraft?.actionId, original.actionId);
      expect(changed.matchesDraft(blocked.rearmedDraft!), isTrue);

      final refreshed = LogicalSendAdmissionResult.ready(
        _receipt('rearmed', actionId: rearmed.actionId, revision: changed),
      );
      expect(refreshed.isReady, isTrue);
      expect(refreshed.receipt?.actionId, original.actionId);
    });

    test('revision tracker is stable for identical evidence and monotonic for every meaningful change', () {
      final tracker = LogicalAuthorityRevisionTracker(seedEpoch: 40);
      final initial = tracker.observe(certificateRevision: 'certificate-v1', authorityRevision: 'authority-v1');
      final identical = tracker.observe(certificateRevision: 'certificate-v1', authorityRevision: 'authority-v1');
      final authorityChanged = tracker.observe(
        certificateRevision: 'certificate-v1',
        authorityRevision: 'authority-v2',
      );
      final certificateChanged = tracker.observe(
        certificateRevision: 'certificate-v2',
        authorityRevision: 'authority-v2',
      );
      final invalidated = tracker.invalidate('PROVIDER_EVIDENCE_UNAVAILABLE');

      expect(initial.epoch, 41);
      expect(identical.epoch, initial.epoch);
      expect(authorityChanged.epoch, initial.epoch + 1);
      expect(certificateChanged.epoch, authorityChanged.epoch + 1);
      expect(invalidated.epoch, certificateChanged.epoch + 1);
      expect(invalidated.authorityRevision, isNot(certificateChanged.authorityRevision));
    });

    test('new provider observation invalidates an older completed admission snapshot while in flight', () {
      final tracker = LogicalEvidenceObservationEpochTracker();
      final first = tracker.begin();
      tracker.complete(first);

      expect(tracker.isCurrent(first), isTrue);

      final second = tracker.begin();
      expect(tracker.isCurrent(first), isFalse);
      expect(tracker.isCurrent(second), isFalse);

      tracker.complete(second);
      expect(tracker.isCurrent(second), isTrue);
      expect(() => tracker.complete(first), throwsStateError);
    });

    test('locally observed mutation invalidates an in-flight provider observation', () {
      final tracker = LogicalEvidenceObservationEpochTracker();
      final stale = tracker.begin();

      tracker.invalidate();

      expect(tracker.isCurrent(stale), isFalse);
      expect(() => tracker.complete(stale), throwsStateError);
      final refreshed = tracker.begin();
      tracker.complete(refreshed);
      expect(tracker.isCurrent(refreshed), isTrue);
    });

    test('unchanged user intent keeps its revision while changed intent advances it', () {
      final original = _draft();
      final unchanged = original.mergeUserIntent(
        text: original.text,
        subject: original.subject,
        attachments: original.attachments,
        reply: original.reply,
        effectId: original.effectId,
        updatedAtEpochMilliseconds: 1200,
      );
      final changed = unchanged.mergeUserIntent(
        text: '${unchanged.text}.',
        subject: unchanged.subject,
        attachments: unchanged.attachments,
        reply: unchanged.reply,
        effectId: unchanged.effectId,
        updatedAtEpochMilliseconds: 1300,
      );

      expect(unchanged.contentRevision, original.contentRevision);
      expect(unchanged.actionId, original.actionId);
      expect(changed.contentRevision, original.contentRevision + 1);
      expect(changed.actionId, isNot(original.actionId));
    });

    test('caller mutation cannot alter frozen attachment intent or action identity', () {
      final selected = <LogicalAttachmentIntent>[_attachment];
      final draft = _draft(attachments: selected, reply: null);
      final originalActionId = draft.actionId;
      final originalRevision = draft.contentRevision;

      selected.add(_ephemeralAttachment);

      expect(draft.attachments.map((item) => item.intentId), <String>[_attachment.intentId]);
      expect(draft.contentRevision, originalRevision);
      expect(draft.actionId, originalActionId);
    });
  });

  group('exact intent serialization', () {
    test('attachment and reply provenance survive a durable JSON round trip exactly', () {
      final original = _draft();
      final restored = LogicalDraft.fromJson(_jsonRoundTrip(original.toJson()));

      expect(restored.toJson(), original.toJson());
      expect(restored.logicalId, original.logicalId);
      expect(restored.contentFingerprint, original.contentFingerprint);
      expect(restored.actionId, original.actionId);
      expect(restored.attachments, hasLength(2));
      expect(restored.attachments.first.intentId, _attachment.intentId);
      expect(restored.attachments.first.name, _attachment.name);
      expect(restored.attachments.first.size, _attachment.size);
      expect(restored.attachments.first.path, _attachment.path);
      expect(restored.attachments.first.mimeType, _attachment.mimeType);
      expect(restored.attachments.first.isRestorable, isTrue);
      expect(restored.attachments.last.intentId, _ephemeralAttachment.intentId);
      expect(restored.attachments.last.path, isNull);
      expect(restored.attachments.last.isRestorable, isFalse);
      expect(restored.reply?.messageGuid, _reply.messageGuid);
      expect(restored.reply?.relationshipTargetGuid, _reply.relationshipTargetGuid);
      expect(restored.reply?.sourceChatRowId, _reply.sourceChatRowId);
      expect(restored.reply?.sourceChatGuid, _reply.sourceChatGuid);
      expect(restored.reply?.part, _reply.part);
      expect(restored.compositionCertificateRevision, original.compositionCertificateRevision);
      expect(restored.compositionAuthorityRevision, original.compositionAuthorityRevision);
      expect(restored.compositionAuthorityEpoch, original.compositionAuthorityEpoch);
    });

    test('unsupported schema and malformed attachment entries fail closed', () {
      final unsupported = _draft().toJson()..['schema'] = 'LOGICAL_DRAFT_FUTURE';
      expect(() => LogicalDraft.fromJson(unsupported), throwsFormatException);

      final malformed = _draft().toJson()
        ..['attachments'] = <dynamic>[_attachment.toJson(), 'CORRUPT_ATTACHMENT_ENTRY'];
      expect(() => LogicalDraft.fromJson(malformed), throwsA(anything));

      final malformedReply = _draft().toJson()..['reply'] = 'CORRUPT_REPLY_PROVENANCE';
      expect(() => LogicalDraft.fromJson(malformedReply), throwsA(anything));
    });
  });

  group('bounded admission states', () {
    final mappings = <String, LogicalSendAdmissionState>{
      'SEND_BLOCKED_ROUTE_AMBIGUOUS': LogicalSendAdmissionState.routeAmbiguous,
      'SEND_BLOCKED_AUTHORITY_CHANGED': LogicalSendAdmissionState.authorityChanged,
      'SEND_BLOCKED_MEMBERSHIP_CERTIFICATE_CHANGED': LogicalSendAdmissionState.authorityChanged,
      'SEND_BLOCKED_PARTICIPANT_SET_CHANGED': LogicalSendAdmissionState.participantSetChanged,
      'SEND_BLOCKED_ACCOUNT_CHANGED': LogicalSendAdmissionState.accountChanged,
      'SEND_BLOCKED_SERVICE_CHANGED': LogicalSendAdmissionState.serviceChanged,
      'SEND_BLOCKED_PROVIDER_EVIDENCE_UNAVAILABLE': LogicalSendAdmissionState.providerEvidenceUnavailable,
      'SEND_BLOCKED_REPLY_TARGET_INVALID': LogicalSendAdmissionState.replyTargetInvalid,
      'SEND_BLOCKED_ATTACHMENT_INTENT_INVALID': LogicalSendAdmissionState.attachmentIntentInvalid,
      'SEND_BLOCKED_DUPLICATE_LOGICAL_ACTION': LogicalSendAdmissionState.duplicateAction,
      'SEND_BLOCKED_QUALIFIED_TARGET_BINDING_NOT_UNIQUE': LogicalSendAdmissionState.targetBindingInvalid,
    };

    for (final mapping in mappings.entries) {
      test('${mapping.key} maps to ${mapping.value.name}', () {
        expect(logicalSendAdmissionStateForReason(mapping.key), mapping.value);
      });
    }

    test('unrecognized failures remain bounded as unsupported', () {
      expect(logicalSendAdmissionStateForReason('SEND_BLOCKED_UNRECOGNIZED'), LogicalSendAdmissionState.unsupported);
    });
  });

  group('receipt and durable admission ledger', () {
    test('persistent parser marks wrong top-level and mixed-element JSON corrupt', () {
      final wrongTopLevel = LogicalAdmissionLedger.fromEntries(decodeLogicalAdmissionLedger('{}'));
      final mixedElements = LogicalAdmissionLedger.fromEntries(
        decodeLogicalAdmissionLedger(jsonEncode(<dynamic>[_receipt('valid-entry').toJson(), 'bad-entry'])),
      );

      expect(wrongTopLevel.isCorrupt, isTrue);
      expect(mixedElements.isCorrupt, isTrue);
      expect(LogicalAdmissionLedger.fromEntries(decodeLogicalAdmissionLedger('')).isCorrupt, isTrue);
      expect(decodeLogicalAdmissionLedger(null), isEmpty);
    });

    test('receipt binds one exact physical target and round trips without a target set', () {
      final original = _receipt('one-target');
      final encoded = original.toJson();
      final restored = LogicalSendAdmissionReceipt.fromJson(_jsonRoundTrip(encoded));

      expect(encoded['targetSourceChatRowId'], _sourceChatRowId);
      expect(encoded['targetSourceChatGuid'], _sourceChatGuid);
      expect(encoded.containsKey('targetSourceChatRowIds'), isFalse);
      expect(encoded.containsKey('targetSourceChatGuids'), isFalse);
      expect(restored.admissionId, original.admissionId);
      expect(restored.actionId, original.actionId);
      expect(restored.targetSourceChatRowId, original.targetSourceChatRowId);
      expect(restored.targetSourceChatGuid, original.targetSourceChatGuid);
      expect(restored.transportTempGuid, original.transportTempGuid);
      expect(restored.payloadFingerprint, original.payloadFingerprint);
      expect(restored.providerContextFingerprint, original.providerContextFingerprint);
      expect(restored.authorityRevision, original.authorityRevision);
      expect(restored.authorityEpoch, original.authorityEpoch);
    });

    test('receipt schema corruption is rejected', () {
      final corrupted = _receipt('corrupt').toJson()..['schema'] = 'LOGICAL_SEND_ADMISSION_FUTURE';
      expect(() => LogicalSendAdmissionReceipt.fromJson(corrupted), throwsFormatException);
    });

    test('receipt rejects an empty or non-positive physical target', () {
      final emptyGuid = _receipt('empty-target').toJson()..['targetSourceChatGuid'] = '';
      final invalidRow = _receipt('invalid-row').toJson()..['targetSourceChatRowId'] = 0;
      final invalidProviderContext = _receipt('invalid-provider-context').toJson()
        ..['providerContextFingerprint'] = 'not-a-sha256';

      expect(() => LogicalSendAdmissionReceipt.fromJson(emptyGuid), throwsA(anything));
      expect(() => LogicalSendAdmissionReceipt.fromJson(invalidRow), throwsA(anything));
      expect(() => LogicalSendAdmissionReceipt.fromJson(invalidProviderContext), throwsA(anything));
    });

    test('provider context fingerprint changes for endpoint, auth, or transport capability drift', () {
      String fingerprint({
        String origin = 'https://server-a.example',
        String authKey = 'auth-a',
        bool isMinBigSur = true,
        bool isMinVentura = true,
        bool isMinSonoma = false,
        bool enablePrivateAPI = true,
        bool privateAPISend = true,
        bool privateAPIAttachmentSend = true,
      }) => logicalProviderContextFingerprint(
        origin: origin,
        authKey: authKey,
        isMinBigSur: isMinBigSur,
        isMinVentura: isMinVentura,
        isMinSonoma: isMinSonoma,
        enablePrivateAPI: enablePrivateAPI,
        privateAPISend: privateAPISend,
        privateAPIAttachmentSend: privateAPIAttachmentSend,
      );

      final accepted = fingerprint();
      expect(fingerprint(), accepted);
      expect(fingerprint(origin: 'https://server-b.example'), isNot(accepted));
      expect(fingerprint(authKey: 'auth-b'), isNot(accepted));
      expect(fingerprint(isMinSonoma: true), isNot(accepted));
      expect(fingerprint(enablePrivateAPI: false), isNot(accepted));
      expect(fingerprint(privateAPISend: false), isNot(accepted));
      expect(fingerprint(privateAPIAttachmentSend: false), isNot(accepted));
    });

    test('receipt rejects a missing or malformed immutable payload binding', () {
      final missing = _receipt('missing-payload').toJson()..remove('payloadFingerprint');
      final malformed = _receipt('malformed-payload').toJson()..['payloadFingerprint'] = 'not-a-sha256';

      expect(() => LogicalSendAdmissionReceipt.fromJson(missing), throwsA(anything));
      expect(() => LogicalSendAdmissionReceipt.fromJson(malformed), throwsFormatException);
    });

    test('batch admission is atomic and any repeated key blocks the entire second batch', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      final first = _receipt('batch-1');
      final second = _receipt('batch-2');
      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[first, second],
          <String>['initial:${first.actionId}', 'initial:${second.actionId}'],
        ),
        isTrue,
      );

      final before = ledger.entries;
      final repeated = _receipt('batch-3', actionId: second.actionId);
      final fresh = _receipt('batch-4');
      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[repeated, fresh],
          <String>['initial:${repeated.actionId}', 'initial:${fresh.actionId}'],
        ),
        isFalse,
      );
      expect(ledger.entries, before);
      expect(ledger.containsAny(<String>['initial:${fresh.actionId}']), isFalse);
    });

    test('duplicate receipt identities cannot create a corrupt committed batch', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      final first = _receipt('same-receipt', actionId: 'first-action');
      final second = _receipt('same-receipt', actionId: 'second-action');

      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[first, second],
          <String>['initial:${first.actionId}', 'initial:${second.actionId}'],
        ),
        isFalse,
      );
      expect(ledger.entries, isEmpty);
    });

    test('one transport temp identity cannot be admitted for two physical executions', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      final first = _receipt('transport-once');
      final second = LogicalSendAdmissionReceipt(
        admissionId: 'admission-second',
        actionId: 'action-second',
        logicalId: first.logicalId,
        draftContentRevision: first.draftContentRevision,
        certificateRevision: first.certificateRevision,
        authorityRevision: first.authorityRevision,
        authorityEpoch: first.authorityEpoch,
        targetSourceChatRowId: first.targetSourceChatRowId,
        targetSourceChatGuid: first.targetSourceChatGuid,
        transportTempGuid: first.transportTempGuid,
        payloadFingerprint: first.payloadFingerprint,
        providerContextFingerprint: first.providerContextFingerprint,
        committedAtEpochMilliseconds: first.committedAtEpochMilliseconds,
      );

      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[first], <String>['initial:${first.actionId}']), isTrue);
      expect(ledger.containsTransportTempGuid(first.transportTempGuid), isTrue);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[second], <String>['retry:${second.actionId}']), isFalse);
      expect(ledger.entries, hasLength(1));
    });

    test('oversized failed batch does not prune or otherwise mutate committed history', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[], capacity: 1);
      final existing = _receipt('existing');
      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[existing], <String>['initial:${existing.actionId}']),
        isTrue,
      );
      expect(
        ledger.transition(existing.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );
      expect(
        ledger.transition(
          existing.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.confirmed,
        ),
        isTrue,
      );
      final before = ledger.entries;
      final tooLarge1 = _receipt('too-large-1');
      final tooLarge2 = _receipt('too-large-2');

      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[tooLarge1, tooLarge2],
          <String>['initial:${tooLarge1.actionId}', 'initial:${tooLarge2.actionId}'],
        ),
        isFalse,
      );
      expect(ledger.entries, before);
    });

    test('confirmed tombstones are retained and capacity exhaustion fails closed', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[], capacity: 1);
      final confirmed = _receipt('retained-confirmed');
      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[confirmed], <String>['initial:${confirmed.actionId}']),
        isTrue,
      );
      expect(
        ledger.transition(
          confirmed.admissionId,
          LogicalOperationState.admitted,
          LogicalOperationState.dispatchReserved,
        ),
        isTrue,
      );
      expect(
        ledger.transition(
          confirmed.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.confirmed,
        ),
        isTrue,
      );
      final replacement = _receipt('replacement');

      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[replacement], <String>['initial:${replacement.actionId}']),
        isFalse,
      );
      expect(ledger.entries.single['admissionId'], confirmed.admissionId);
    });

    test('pre-dispatch authority race can roll back only the intact admitted batch', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      final first = _receipt('rollback-1');
      final second = _receipt('rollback-2');
      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[first, second],
          <String>['initial:${first.actionId}', 'initial:${second.actionId}'],
        ),
        isTrue,
      );
      expect(ledger.rollbackAdmittedBatch(<String>[first.admissionId, second.admissionId]), isTrue);
      expect(ledger.entries, isEmpty);

      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[first], <String>['initial:${first.actionId}']), isTrue);
      expect(
        ledger.transition(first.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );
      final before = ledger.entries;
      expect(ledger.rollbackAdmittedBatch(<String>[first.admissionId]), isFalse);
      expect(ledger.entries, before);
    });

    test('post-persistence pre-transport race can roll back a dispatch reservation', () {
      final receipt = _receipt('reserved-rollback');
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[receipt], <String>['initial:${receipt.actionId}']),
        isTrue,
      );
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );

      expect(ledger.rollbackBeforeTransportBatch(<String>[receipt.admissionId]), isTrue);
      expect(ledger.entries, isEmpty);
    });

    test('double tap admits and dispatches one physical execution at most once', () {
      final receipt = _receipt('double-tap');
      final harness = _DispatchHarness(receipt);

      expect(harness.commit(), isTrue);
      expect(
        harness.ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[_receipt('second-tap', actionId: receipt.actionId)],
          <String>['initial:${receipt.actionId}'],
        ),
        isFalse,
      );
      expect(harness.dispatch(), isTrue);
      expect(harness.dispatch(), isFalse);
      expect(harness.dispatchCount, 1);
    });

    test('caller cannot alias one action under a second initial admission key', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      const actionId = 'one-human-action';
      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[_receipt('canonical', actionId: actionId)],
          <String>['initial:$actionId'],
        ),
        isTrue,
      );

      expect(
        ledger.commitBatch(
          <LogicalSendAdmissionReceipt>[_receipt('aliased', actionId: actionId)],
          <String>['initial:forged-alias'],
        ),
        isFalse,
      );
      expect(ledger.entries, hasLength(1));
    });

    test('retry namespace cannot create a second receipt for one action', () {
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      const actionId = 'one-action-across-retry-modes';
      final initial = _receipt('initial-mode', actionId: actionId);
      final retry = _receipt('retry-mode', actionId: actionId);

      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[initial], <String>['initial:$actionId']), isTrue);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[retry], <String>['retry:$actionId']), isFalse);
      expect(ledger.entries, hasLength(1));
    });

    test('lifecycle and reconnect reconstruction retain commitment and cannot redispatch', () {
      final receipt = _receipt('reconstruction');
      final harness = _DispatchHarness(receipt);
      expect(harness.commit(), isTrue);

      harness.recreate();
      expect(_stateOf(harness.ledger, receipt.admissionId), LogicalOperationState.admitted);
      expect(harness.dispatch(), isTrue);

      harness.recreate();
      expect(_stateOf(harness.ledger, receipt.admissionId), LogicalOperationState.confirmed);
      expect(harness.commit(), isFalse);
      expect(harness.dispatch(), isFalse);
      expect(harness.dispatchCount, 1);
    });

    test('corrupt restored ledger is marked unavailable and refuses new admission', () {
      final receipt = _receipt('corrupt-ledger');
      final invalidState = <String, dynamic>{
        ...receipt.toJson(),
        'admissionKey': 'initial:${receipt.actionId}',
        'operationState': 'repositoryMayRetry',
      };
      final ledger = LogicalAdmissionLedger.fromEntries(<Map<String, dynamic>>[invalidState]);
      final fresh = _receipt('new');

      expect(ledger.isCorrupt, isTrue);
      expect(ledger.entries, isEmpty);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[fresh], <String>['initial:${fresh.actionId}']), isFalse);
    });

    test('mixed corrupt restoration cannot transition its retained valid entry', () {
      final receipt = _receipt('valid-among-corruption');
      final valid = <String, dynamic>{
        ...receipt.toJson(),
        'admissionKey': 'initial:${receipt.actionId}',
        'operationState': LogicalOperationState.admitted.name,
      };
      final malformed = <String, dynamic>{'schema': 'BROKEN'};
      final ledger = LogicalAdmissionLedger.fromEntries(<Map<String, dynamic>>[valid, malformed]);
      final before = ledger.entries;

      expect(ledger.isCorrupt, isTrue);
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isFalse,
      );
      expect(ledger.entries, before);
    });

    test('duplicate persisted admission identity is corruption and fails closed', () {
      final receipt = _receipt('persisted-duplicate');
      final entry = <String, dynamic>{
        ...receipt.toJson(),
        'admissionKey': 'initial:${receipt.actionId}',
        'operationState': LogicalOperationState.admitted.name,
      };
      final duplicate = <String, dynamic>{...entry, 'admissionKey': 'initial:other-key'};
      final ledger = LogicalAdmissionLedger.fromEntries(<Map<String, dynamic>>[entry, duplicate]);
      final fresh = _receipt('newer');

      expect(ledger.isCorrupt, isTrue);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[fresh], <String>['initial:${fresh.actionId}']), isFalse);
    });

    test('operation state machine permits only reserve then one terminal transition', () {
      final receipt = _receipt('state-machine');
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[receipt], <String>['initial:${receipt.actionId}']),
        isTrue,
      );

      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.admitted, LogicalOperationState.confirmed),
        isFalse,
      );
      expect(_stateOf(ledger, receipt.admissionId), LogicalOperationState.admitted);
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isFalse,
      );
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.dispatchReserved, LogicalOperationState.confirmed),
        isTrue,
      );
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.confirmed, LogicalOperationState.admitted),
        isFalse,
      );
      expect(_stateOf(ledger, receipt.admissionId), LogicalOperationState.confirmed);
    });

    test('unknown dispatch outcome is terminal and reconstruction never retries it', () {
      final receipt = _receipt('unknown-outcome');
      final harness = _DispatchHarness(receipt);
      expect(harness.commit(), isTrue);
      expect(harness.dispatch(outcomeUnknown: true), isTrue);
      expect(harness.dispatchCount, 1);

      harness.recreate();
      expect(_stateOf(harness.ledger, receipt.admissionId), LogicalOperationState.outcomeUnknown);
      expect(harness.commit(), isFalse);
      expect(harness.dispatch(), isFalse);
      expect(harness.dispatchCount, 1);
    });
  });

  group('authority-change failure injection transaction boundary', () {
    final expected = <_InjectionPoint, _InjectionOutcome>{
      _InjectionPoint.beforeTap: (
        admissionCount: 1,
        attachmentStageCount: 0,
        repositoryCallCount: 0,
        dispatchCount: 0,
        operationState: null,
      ),
      _InjectionPoint.duringAdmission: (
        admissionCount: 1,
        attachmentStageCount: 0,
        repositoryCallCount: 0,
        dispatchCount: 0,
        operationState: null,
      ),
      _InjectionPoint.afterAdmissionBeforeRepositoryCall: (
        admissionCount: 1,
        attachmentStageCount: 0,
        repositoryCallCount: 0,
        dispatchCount: 0,
        operationState: null,
      ),
      _InjectionPoint.duringAttachmentStaging: (
        admissionCount: 1,
        attachmentStageCount: 1,
        repositoryCallCount: 0,
        dispatchCount: 0,
        operationState: null,
      ),
      _InjectionPoint.duringAsyncSend: (
        admissionCount: 1,
        attachmentStageCount: 0,
        repositoryCallCount: 1,
        dispatchCount: 1,
        operationState: LogicalOperationState.outcomeUnknown,
      ),
      _InjectionPoint.duringUiLifecycleRecreation: (
        admissionCount: 1,
        attachmentStageCount: 0,
        repositoryCallCount: 1,
        dispatchCount: 1,
        operationState: LogicalOperationState.outcomeUnknown,
      ),
    };

    for (final point in _InjectionPoint.values) {
      test('${point.label}: dispatch count is ${expected[point]!.dispatchCount}', () {
        final outcome = _runInjection(point);
        expect(outcome.admissionCount, expected[point]!.admissionCount);
        expect(outcome.attachmentStageCount, expected[point]!.attachmentStageCount);
        expect(outcome.repositoryCallCount, expected[point]!.repositoryCallCount);
        expect(outcome.dispatchCount, expected[point]!.dispatchCount);
        expect(outcome.operationState, expected[point]!.operationState);
      });
    }
  });
}
