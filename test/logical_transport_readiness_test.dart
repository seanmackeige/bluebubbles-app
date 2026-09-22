import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _now = 2_000_000;

LogicalRouteCandidateEvidence _smsCandidate({
  List<LogicalSuccessfulOutboundEvidence> successful = const <LogicalSuccessfulOutboundEvidence>[],
  List<LogicalRouteMessageEvidence> messages = const <LogicalRouteMessageEvidence>[],
}) => LogicalRouteCandidateEvidence(
  sourceChatRowId: 2156,
  sourceChatGuid: 'SMS;-;redacted-logical-target',
  sourceService: 'SMS',
  chatIdentifier: 'redacted',
  style: 43,
  lastAddressedHandle: const LogicalAddressEvidence(address: 'redacted-self'),
  participants: const <LogicalAddressEvidence>[LogicalAddressEvidence(address: 'redacted-member')],
  chatSnapshotComplete: true,
  messageSnapshotComplete: true,
  lastKnownHybridState: false,
  shouldForceToSms: true,
  lastSeenMessageGuid: 'last-seen',
  groupPhotoGuid: null,
  messages: messages,
  successfulOutbounds: successful,
);

LogicalRouteEvidence _evidence(LogicalRouteCandidateEvidence candidate, {bool detectedIMessage = true}) =>
    LogicalRouteEvidence(
      logicalId: 'logical-redacted',
      certificateId: 'certificate-redacted',
      certifiedSourceChatGuids: <int, String>{candidate.sourceChatRowId: candidate.sourceChatGuid},
      backendComputerId: 'backend-redacted',
      detectedIMessage: detectedIMessage,
      privateApiConnected: true,
      helperConnected: true,
      accountSnapshotBeforeSha256: 'account',
      accountSnapshotAfterSha256: 'account',
      activeSelfAlias: const LogicalAddressEvidence(address: 'redacted-self'),
      vettedSelfAliases: const <LogicalAddressEvidence>[LogicalAddressEvidence(address: 'redacted-self')],
      executionGenerationCertificate: null,
      candidateScopeSnapshotComplete: true,
      unadmittedPotentialSourceChatGuids: const <int, String>{},
      candidates: <LogicalRouteCandidateEvidence>[candidate],
    );

LogicalSendAdmissionReceipt _receipt(String suffix, String intentFingerprint) => LogicalSendAdmissionReceipt(
  admissionId: 'admission-$suffix',
  actionId: 'action-$suffix',
  logicalId: 'logical-redacted',
  draftContentRevision: 1,
  certificateRevision: 'certificate',
  authorityRevision: 'authority',
  authorityEpoch: 1,
  targetSourceChatRowId: 2156,
  targetSourceChatGuid: 'SMS;-;redacted-logical-target',
  transportTempGuid: 'temp-$suffix',
  payloadFingerprint: sha256.convert(utf8.encode('payload-$suffix')).toString(),
  intentFingerprint: intentFingerprint,
  providerContextFingerprint: sha256.convert(utf8.encode('provider-$suffix')).toString(),
  transportReadinessRevision: sha256.convert(utf8.encode('transport-$suffix')).toString(),
  transportSendDisposition: LogicalTransportSendDisposition.allowedWithReachabilityUnknown.name,
  committedAtEpochMilliseconds: 1,
);

void main() {
  group('route authority and transport readiness remain separate', () {
    test('recent natural terminal SMS success is time-bounded readiness evidence', () {
      final candidate = _smsCandidate(
        successful: const <LogicalSuccessfulOutboundEvidence>[
          LogicalSuccessfulOutboundEvidence(
            messageGuid: 'success',
            messageRowId: 1,
            createdAtEpoch: _now - 1000,
            terminalAcknowledgement: true,
          ),
        ],
      );
      final readiness = LogicalTransportReadinessPolicy.resolve(
        _evidence(candidate),
        const LogicalRouteDecision.qualified('QUALIFIED', <int>[2156]),
        observedAtEpochMilliseconds: _now,
      );

      expect(readiness.state, LogicalTransportReadinessState.ready);
      expect(readiness.strength, LogicalTransportEvidenceStrength.strongIndicator);
      expect(readiness.sendDispositionAt(_now), LogicalTransportSendDisposition.ready);
      expect(
        readiness.sendDispositionAt(_now + LogicalTransportReadinessPolicy.recentTerminalEvidenceWindow.inMilliseconds),
        LogicalTransportSendDisposition.allowedWithReachabilityUnknown,
      );
    });

    test('SMS route without current reachability proof is allowed only as unknown', () {
      final readiness = LogicalTransportReadinessPolicy.resolve(
        _evidence(_smsCandidate()),
        const LogicalRouteDecision.qualified('QUALIFIED', <int>[2156]),
        observedAtEpochMilliseconds: _now,
      );

      expect(readiness.state, LogicalTransportReadinessState.unknown);
      expect(readiness.reason, 'SMS_RELAY_REACHABILITY_NOT_PROVEN');
      expect(readiness.sendDispositionAt(_now), LogicalTransportSendDisposition.allowedWithReachabilityUnknown);
    });

    test('failed SMS outcome is not promoted into authoritative relay unavailability', () {
      const failed = LogicalRouteMessageEvidence(
        messageGuid: 'failed',
        messageRowId: 2,
        createdAtEpoch: _now - 1000,
        isFromMe: true,
        error: 4,
        itemType: 0,
      );
      final withoutFailure = _evidence(_smsCandidate());
      final withFailure = _evidence(_smsCandidate(messages: const <LogicalRouteMessageEvidence>[failed]));
      final readiness = LogicalTransportReadinessPolicy.resolve(
        withFailure,
        const LogicalRouteDecision.qualified('QUALIFIED', <int>[2156]),
        observedAtEpochMilliseconds: _now,
      );

      expect(withFailure.authorityRevision, withoutFailure.authorityRevision);
      expect(readiness.state, LogicalTransportReadinessState.unknown);
      expect(readiness.strength, LogicalTransportEvidenceStrength.weakIndicator);
      expect(readiness.sendDispositionAt(_now), LogicalTransportSendDisposition.allowedWithReachabilityUnknown);
    });

    test('only authoritative unavailability blocks before execution', () {
      const unavailable = LogicalTransportReadinessEvidence(
        service: 'SMS',
        state: LogicalTransportReadinessState.unavailable,
        strength: LogicalTransportEvidenceStrength.authoritative,
        reason: 'PROVIDER_RELAY_UNAVAILABLE',
        observedAtEpochMilliseconds: _now,
      );
      const weakUnavailable = LogicalTransportReadinessEvidence(
        service: 'SMS',
        state: LogicalTransportReadinessState.unavailable,
        strength: LogicalTransportEvidenceStrength.weakIndicator,
        reason: 'INFERRED_ONLY',
        observedAtEpochMilliseconds: _now,
      );

      expect(unavailable.sendDispositionAt(_now), LogicalTransportSendDisposition.blocked);
      expect(weakUnavailable.sendDispositionAt(_now), LogicalTransportSendDisposition.allowedWithReachabilityUnknown);
    });
  });

  group('relay timeout and recovery exactly-once semantics', () {
    test('relay recovery never changes or retries an ambiguous old operation', () {
      final intent = sha256.convert(utf8.encode('same-human-content')).toString();
      final old = _receipt('old', intent);
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[old], <String>['initial:${old.actionId}']), isTrue);
      expect(
        ledger.transition(old.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );
      expect(
        ledger.transition(
          old.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.outcomeUnknown,
        ),
        isTrue,
      );

      // A later relay observation is external evidence. It cannot mutate the
      // durable operation state or make the old action dispatchable again.
      const recoveredRelay = LogicalTransportReadinessEvidence(
        service: 'SMS',
        state: LogicalTransportReadinessState.ready,
        strength: LogicalTransportEvidenceStrength.strongIndicator,
        reason: 'RECENT_NATURAL_SMS_TERMINAL_SUCCESS',
        observedAtEpochMilliseconds: _now,
      );
      expect(recoveredRelay.sendDispositionAt(_now), LogicalTransportSendDisposition.ready);
      expect(ledger.entries.single['operationState'], LogicalOperationState.outcomeUnknown.name);
      expect(ledger.hasAmbiguousOutcomeForLogical(old.logicalId), isTrue);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[old], <String>['initial:${old.actionId}']), isFalse);
      expect(logicalTransportMayRetry(old), isFalse);
      expect(logicalSocketEchoMayComplete(old), isFalse);
    });

    test('same-content future resend requires acknowledgement and a new operation identity', () {
      final intent = sha256.convert(utf8.encode('same-human-content')).toString();
      final old = _receipt('old', intent);
      final next = _receipt('new', intent);
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      expect(ledger.commitBatch(<LogicalSendAdmissionReceipt>[old], <String>['initial:${old.actionId}']), isTrue);
      expect(
        ledger.transition(old.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );
      expect(
        ledger.transition(
          old.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.outcomeUnknown,
        ),
        isTrue,
      );

      expect(
        ledger.permitsExplicitNewOperation(
          logicalId: old.logicalId,
          intentFingerprint: intent,
          acknowledgedAmbiguousAdmissionId: null,
          newActionId: next.actionId,
        ),
        isFalse,
      );
      expect(
        ledger.permitsExplicitNewOperation(
          logicalId: old.logicalId,
          intentFingerprint: intent,
          acknowledgedAmbiguousAdmissionId: old.admissionId,
          newActionId: old.actionId,
        ),
        isFalse,
      );
      expect(
        ledger.permitsExplicitNewOperation(
          logicalId: old.logicalId,
          intentFingerprint: intent,
          acknowledgedAmbiguousAdmissionId: old.admissionId,
          newActionId: next.actionId,
        ),
        isTrue,
      );
    });

    test('unledgered provider operation is never attributed to Sean Edition', () {
      final intent = sha256.convert(utf8.encode('content')).toString();
      final receipt = _receipt('sean', intent);
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      expect(
        ledger.originForTransportTempGuid('official-client-temp'),
        LogicalOperationOrigin.externalOrLegacyUnattributed,
      );
      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[receipt], <String>['initial:${receipt.actionId}']),
        isTrue,
      );
      expect(ledger.originForTransportTempGuid(receipt.transportTempGuid), LogicalOperationOrigin.seanEditionLedger);
    });
  });
}
