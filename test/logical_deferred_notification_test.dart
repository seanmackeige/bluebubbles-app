import 'package:bluebubbles/services/backend/notifications/logical_deferred_notification.dart';
import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  LogicalDeferredNotification record(String message, String source, int time) =>
      LogicalDeferredNotification(messageGuid: message, sourceChatGuid: source, enqueuedAtEpochMilliseconds: time);

  test('only protected uncertified events are deferred', () {
    expect(
      shouldDeferProtectedLogicalNotification(isPotentialLogicalSource: true, isCertifiedLogicalConversation: false),
      isTrue,
    );
    expect(
      shouldDeferProtectedLogicalNotification(isPotentialLogicalSource: true, isCertifiedLogicalConversation: true),
      isFalse,
    );
    expect(
      shouldDeferProtectedLogicalNotification(isPotentialLogicalSource: false, isCertifiedLogicalConversation: false),
      isFalse,
    );
  });

  test('active candidate phases defer while terminal phases emit read-only', () {
    for (final phase in <LogicalCandidateQuarantinePhase>[
      LogicalCandidateQuarantinePhase.nominated,
      LogicalCandidateQuarantinePhase.reconciling,
      LogicalCandidateQuarantinePhase.certified,
    ]) {
      expect(
        resolveProtectedLogicalNotification(
          isPotentialLogicalSource: true,
          isCertifiedLogicalConversation: false,
          candidatePhase: phase,
        ),
        LogicalProtectedNotificationDisposition.defer,
      );
    }
    for (final phase in <LogicalCandidateQuarantinePhase>[
      LogicalCandidateQuarantinePhase.rejected,
      LogicalCandidateQuarantinePhase.expiredVisible,
    ]) {
      expect(
        resolveProtectedLogicalNotification(
          isPotentialLogicalSource: true,
          isCertifiedLogicalConversation: false,
          candidatePhase: phase,
        ),
        LogicalProtectedNotificationDisposition.emitReadOnly,
      );
    }
  });

  test('active certificate and ordinary identity always emit normally', () {
    expect(
      resolveProtectedLogicalNotification(
        isPotentialLogicalSource: true,
        isCertifiedLogicalConversation: true,
        candidatePhase: LogicalCandidateQuarantinePhase.certified,
      ),
      LogicalProtectedNotificationDisposition.emitNormal,
    );
    expect(
      resolveProtectedLogicalNotification(
        isPotentialLogicalSource: false,
        isCertifiedLogicalConversation: false,
        candidatePhase: null,
      ),
      LogicalProtectedNotificationDisposition.emitNormal,
    );
  });

  test('deferred exact event is durable, deterministic, and idempotent', () {
    final first = LogicalDeferredNotificationLedger.empty()
        .defer(record('message-b', 'source-b', 20), nowEpochMilliseconds: 20)
        .defer(record('message-a', 'source-a', 10), nowEpochMilliseconds: 20)
        .defer(record('message-a', 'source-a', 999), nowEpochMilliseconds: 20);
    final restored = LogicalDeferredNotificationLedger.decode(first.encode());
    expect(restored.entries.map((entry) => entry.messageGuid), <String>['message-a', 'message-b']);
    expect(restored.encode(), first.encode());
  });

  test('completion removes only the exact source event', () {
    final ledger = LogicalDeferredNotificationLedger.empty()
        .defer(record('same-message', 'source-a', 1), nowEpochMilliseconds: 1)
        .defer(record('same-message', 'source-b', 2), nowEpochMilliseconds: 2);
    final updated = ledger.remove(record('same-message', 'source-a', 1).key);
    expect(updated.entries, hasLength(1));
    expect(updated.entries.single.sourceChatGuid, 'source-b');
  });

  test('expired and corrupt entries fail closed', () {
    final expiredAt = logicalDeferredNotificationTtl.inMilliseconds + 2;
    final ledger = LogicalDeferredNotificationLedger.empty().defer(
      record('message', 'source', 1),
      nowEpochMilliseconds: 1,
    );
    expect(ledger.prune(nowEpochMilliseconds: expiredAt).entries, isEmpty);
    expect(() => LogicalDeferredNotificationLedger.decode('{"schema":"wrong","entries":[]}'), throwsFormatException);
  });

  test('bounded queue drops the oldest event without changing newer identity', () {
    var ledger = LogicalDeferredNotificationLedger.empty();
    for (var index = 0; index <= logicalDeferredNotificationMaxEntries; index++) {
      ledger = ledger.defer(record('message-$index', 'source', index), nowEpochMilliseconds: index);
    }
    expect(ledger.entries, hasLength(logicalDeferredNotificationMaxEntries));
    expect(ledger.entries.first.messageGuid, 'message-1');
    expect(ledger.entries.last.messageGuid, 'message-$logicalDeferredNotificationMaxEntries');
  });
}
