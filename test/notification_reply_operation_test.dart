import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/services/backend/java_dart_interop/notification_reply_operation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

NotificationReplyOperationIdentity _identity({
  String conversationKey = 'logical:test-conversation',
  String sourceChatGuid = 'iMessage;-;source-chat-guid',
  String messageGuid = 'source-message-guid',
  String text = 'exact reply text',
}) => NotificationReplyOperationIdentity.fromExactInput(
  conversationKey: conversationKey,
  sourceChatGuid: sourceChatGuid,
  messageGuid: messageGuid,
  text: text,
);

NotificationReplyOperationState? _state(
  String? raw,
  NotificationReplyOperationIdentity identity,
) => NotificationReplyOperationJournal.decode(raw).recordFor(identity)?.state;

class _JournalStore {
  String? raw;
  bool Function(NotificationReplyOperationState? state)? rejectSave;
  final List<NotificationReplyOperationState?> savedStates =
      <NotificationReplyOperationState?>[];

  Future<String?> load() async => raw;

  Future<void> save(
    String value,
    NotificationReplyOperationIdentity identity,
  ) async {
    final state = _state(value, identity);
    if (rejectSave?.call(state) ?? false) {
      throw StateError('injected journal failure');
    }
    raw = value;
    savedStates.add(state);
  }
}

NotificationReplyOperationCoordinator _coordinator(
  _JournalStore store,
  NotificationReplyOperationIdentity identity, {
  int processId = 1,
}) => NotificationReplyOperationCoordinator(
  processFingerprint: notificationReplyProcessFingerprint(processId),
  load: store.load,
  save: (value) => store.save(value, identity),
  attemptIdFactory: (operationId, ordinal) =>
      _hash('$operationId:$processId:$ordinal'),
);

void main() {
  group('NotificationReplyOperationIdentity', () {
    test('is exact, deterministic, and persists no raw identity or text', () {
      final first = _identity();
      final second = _identity();
      final changedSource = _identity(sourceChatGuid: 'iMessage;-;different');
      final changedMessage = _identity(messageGuid: 'different-message');
      final changedText = _identity(text: 'different reply');

      expect(second, first);
      expect(changedSource, isNot(first));
      expect(changedMessage, isNot(first));
      expect(changedText, isNot(first));

      final decision = NotificationReplyOperationJournal.empty().begin(
        identity: first,
        attemptId: _hash('attempt'),
        processFingerprint: notificationReplyProcessFingerprint(1),
      );
      final encoded = decision.journal.encode();

      expect(encoded, isNot(contains('logical:test-conversation')));
      expect(encoded, isNot(contains('source-chat-guid')));
      expect(encoded, isNot(contains('source-message-guid')));
      expect(encoded, isNot(contains('exact reply text')));
      expect(
        NotificationReplyOperationJournal.decode(
          encoded,
        ).recordFor(first)?.identity,
        first,
      );
    });

    test('rejects incomplete exact input', () {
      expect(() => _identity(text: ''), throwsA(isA<FormatException>()));
    });
  });

  group('NotificationReplyOperationCoordinator', () {
    test(
      'crosses boundary once and makes terminal duplicate a no-op',
      () async {
        final identity = _identity();
        final store = _JournalStore();
        final coordinator = _coordinator(store, identity);
        var providerDispatches = 0;

        final first = await coordinator.execute(
          identity: identity,
          dispatch: (markExecutionStarted) async {
            expect(
              _state(store.raw, identity),
              NotificationReplyOperationState.reserved,
            );
            await markExecutionStarted();
            await markExecutionStarted();
            expect(
              _state(store.raw, identity),
              NotificationReplyOperationState.executionStarted,
            );
            providerDispatches++;
          },
        );
        var duplicateClosureCalled = false;
        final duplicate = await coordinator.execute(
          identity: identity,
          dispatch: (_) async {
            duplicateClosureCalled = true;
          },
        );

        expect(
          first.disposition,
          NotificationReplyExecutionDisposition.terminal,
        );
        expect(first.shouldCommitWorker, isTrue);
        expect(
          duplicate.disposition,
          NotificationReplyExecutionDisposition.alreadyTerminal,
        );
        expect(duplicate.shouldCommitWorker, isTrue);
        expect(duplicateClosureCalled, isFalse);
        expect(providerDispatches, 1);
        expect(
          _state(store.raw, identity),
          NotificationReplyOperationState.terminal,
        );
      },
    );

    test('pre-execution rejection is explicitly retryable', () async {
      final identity = _identity();
      final store = _JournalStore();
      final coordinator = _coordinator(store, identity);
      var providerDispatches = 0;

      final rejected = await coordinator.execute(
        identity: identity,
        dispatch: (_) async {
          throw StateError('injected pre-admission rejection');
        },
      );
      final retried = await coordinator.execute(
        identity: identity,
        dispatch: (markExecutionStarted) async {
          await markExecutionStarted();
          providerDispatches++;
        },
      );

      expect(
        rejected.disposition,
        NotificationReplyExecutionDisposition.preExecutionRejected,
      );
      expect(rejected.shouldCommitWorker, isFalse);
      expect(
        retried.disposition,
        NotificationReplyExecutionDisposition.terminal,
      );
      expect(providerDispatches, 1);
      expect(
        store.savedStates,
        contains(NotificationReplyOperationState.preExecutionRejected),
      );
    });

    test('return before boundary is pre-execution rejected', () async {
      final identity = _identity();
      final store = _JournalStore();

      final result = await _coordinator(
        store,
        identity,
      ).execute(identity: identity, dispatch: (_) async {});

      expect(
        result.disposition,
        NotificationReplyExecutionDisposition.preExecutionRejected,
      );
      expect(
        _state(store.raw, identity),
        NotificationReplyOperationState.preExecutionRejected,
      );
    });

    test('post-boundary failure is ambiguous and never replayed', () async {
      final identity = _identity();
      final store = _JournalStore();
      var providerDispatches = 0;

      final first = await _coordinator(store, identity).execute(
        identity: identity,
        dispatch: (markExecutionStarted) async {
          await markExecutionStarted();
          providerDispatches++;
          throw StateError('injected provider disconnect');
        },
      );
      var replayCalled = false;
      final replay = await _coordinator(store, identity, processId: 2).execute(
        identity: identity,
        dispatch: (_) async {
          replayCalled = true;
        },
      );

      expect(
        first.disposition,
        NotificationReplyExecutionDisposition.outcomeAmbiguous,
      );
      expect(
        replay.disposition,
        NotificationReplyExecutionDisposition.outcomeAmbiguous,
      );
      expect(first.shouldCommitWorker, isFalse);
      expect(replayCalled, isFalse);
      expect(providerDispatches, 1);
      expect(
        _state(store.raw, identity),
        NotificationReplyOperationState.outcomeAmbiguous,
      );
    });

    test('concurrent duplicate worker cannot dispatch', () async {
      final identity = _identity();
      final store = _JournalStore();
      final coordinator = _coordinator(store, identity);
      final boundaryCrossed = Completer<void>();
      final releaseProvider = Completer<void>();
      var providerDispatches = 0;

      final firstFuture = coordinator.execute(
        identity: identity,
        dispatch: (markExecutionStarted) async {
          await markExecutionStarted();
          providerDispatches++;
          boundaryCrossed.complete();
          await releaseProvider.future;
        },
      );
      await boundaryCrossed.future;

      var duplicateClosureCalled = false;
      final duplicate = await coordinator.execute(
        identity: identity,
        dispatch: (_) async {
          duplicateClosureCalled = true;
        },
      );
      releaseProvider.complete();
      final first = await firstFuture;

      expect(
        duplicate.disposition,
        NotificationReplyExecutionDisposition.duplicateInFlight,
      );
      expect(duplicateClosureCalled, isFalse);
      expect(first.disposition, NotificationReplyExecutionDisposition.terminal);
      expect(providerDispatches, 1);
    });

    test('restart recovers reserved then dispatches once', () async {
      final identity = _identity();
      final store = _JournalStore();
      store.raw = NotificationReplyOperationJournal.empty()
          .begin(
            identity: identity,
            attemptId: _hash('old-attempt'),
            processFingerprint: notificationReplyProcessFingerprint(1),
          )
          .journal
          .encode();
      var providerDispatches = 0;

      final result = await _coordinator(store, identity, processId: 2).execute(
        identity: identity,
        dispatch: (markExecutionStarted) async {
          await markExecutionStarted();
          providerDispatches++;
        },
      );

      expect(
        result.disposition,
        NotificationReplyExecutionDisposition.terminal,
      );
      expect(providerDispatches, 1);
      expect(
        store.savedStates,
        contains(NotificationReplyOperationState.preExecutionRejected),
      );
    });

    test(
      'restart makes execution_started ambiguous without dispatch',
      () async {
        final identity = _identity();
        final store = _JournalStore();
        final oldAttempt = _hash('old-attempt');
        var journal = NotificationReplyOperationJournal.empty()
            .begin(
              identity: identity,
              attemptId: oldAttempt,
              processFingerprint: notificationReplyProcessFingerprint(1),
            )
            .journal;
        journal = journal.transition(
          identity: identity,
          attemptId: oldAttempt,
          from: NotificationReplyOperationState.reserved,
          to: NotificationReplyOperationState.executionStarted,
        );
        store.raw = journal.encode();
        var dispatchCalled = false;

        final result = await _coordinator(store, identity, processId: 2)
            .execute(
              identity: identity,
              dispatch: (_) async {
                dispatchCalled = true;
              },
            );

        expect(
          result.disposition,
          NotificationReplyExecutionDisposition.outcomeAmbiguous,
        );
        expect(dispatchCalled, isFalse);
        expect(
          _state(store.raw, identity),
          NotificationReplyOperationState.outcomeAmbiguous,
        );
      },
    );

    test('terminal persistence failure reconciles to ambiguous', () async {
      final identity = _identity();
      final store = _JournalStore();
      var rejectedTerminal = false;
      store.rejectSave = (state) {
        if (state == NotificationReplyOperationState.terminal &&
            !rejectedTerminal) {
          rejectedTerminal = true;
          return true;
        }
        return false;
      };

      final result = await _coordinator(store, identity).execute(
        identity: identity,
        dispatch: (markExecutionStarted) async {
          await markExecutionStarted();
        },
      );

      expect(
        result.disposition,
        NotificationReplyExecutionDisposition.outcomeAmbiguous,
      );
      expect(result.shouldCommitWorker, isFalse);
      expect(
        _state(store.raw, identity),
        NotificationReplyOperationState.outcomeAmbiguous,
      );
    });

    test(
      'corrupt or unavailable journal fails closed before dispatch',
      () async {
        final identity = _identity();
        final store = _JournalStore()..raw = '{not-json';
        var dispatchCalled = false;

        final corrupt = await _coordinator(store, identity).execute(
          identity: identity,
          dispatch: (_) async {
            dispatchCalled = true;
          },
        );

        store.raw = null;
        store.rejectSave = (_) => true;
        final unavailable = await _coordinator(store, identity).execute(
          identity: identity,
          dispatch: (_) async {
            dispatchCalled = true;
          },
        );

        expect(
          corrupt.disposition,
          NotificationReplyExecutionDisposition.journalUnavailable,
        );
        expect(
          unavailable.disposition,
          NotificationReplyExecutionDisposition.journalUnavailable,
        );
        expect(dispatchCalled, isFalse);
      },
    );
  });

  group('prepared notification reply rollback', () {
    test(
      'temp GUID is deterministic, exact-operation keyed, and privacy safe',
      () {
        final identity = _identity();
        final first = notificationReplyTempMessageGuid(identity);
        final second = notificationReplyTempMessageGuid(_identity());
        final changed = notificationReplyTempMessageGuid(
          _identity(text: 'another reply'),
        );

        expect(second, first);
        expect(changed, isNot(first));
        expect(first, startsWith('temp-notification-reply-'));
        expect(first, isNot(contains('source-message-guid')));
        expect(first, isNot(contains('exact reply text')));
      },
    );

    test('all local cleanup steps run after a pre-dispatch failure', () async {
      final calls = <NotificationReplyPreparedRollbackStep>[];
      final result = await NotificationReplyPreparedMessageRollback.run(
        deletePersistedMessage: () async {
          calls.add(NotificationReplyPreparedRollbackStep.persistedMessage);
          throw StateError('injected delete failure');
        },
        removePresentationMessage: () async {
          calls.add(NotificationReplyPreparedRollbackStep.presentationMessage);
        },
        restoreLatestMessage: () async {
          calls.add(NotificationReplyPreparedRollbackStep.latestMessage);
        },
      );

      expect(calls, <NotificationReplyPreparedRollbackStep>[
        NotificationReplyPreparedRollbackStep.persistedMessage,
        NotificationReplyPreparedRollbackStep.presentationMessage,
        NotificationReplyPreparedRollbackStep.latestMessage,
      ]);
      expect(result.isComplete, isFalse);
      expect(result.failedSteps, <NotificationReplyPreparedRollbackStep>{
        NotificationReplyPreparedRollbackStep.persistedMessage,
      });
    });

    test('complete local cleanup is reported explicitly', () async {
      var calls = 0;
      final result = await NotificationReplyPreparedMessageRollback.run(
        deletePersistedMessage: () async => calls++,
        removePresentationMessage: () async => calls++,
        restoreLatestMessage: () async => calls++,
      );

      expect(calls, 3);
      expect(result.isComplete, isTrue);
      expect(result.failedSteps, isEmpty);
    });

    test(
      'failed final admission cleans prepared state before provider use',
      () async {
        var persisted = true;
        var presented = true;
        var latest = true;
        var providerCalled = false;
        final admissionError = StateError('injected final journal failure');

        Future<void> execute() async {
          await NotificationReplyPreparedDispatchAdmission.run(
            admit: () async => throw admissionError,
            rollbackPreparedMessage: () async {
              final cleanup =
                  await NotificationReplyPreparedMessageRollback.run(
                    deletePersistedMessage: () async => persisted = false,
                    removePresentationMessage: () async => presented = false,
                    restoreLatestMessage: () async => latest = false,
                  );
              expect(cleanup.isComplete, isTrue);
            },
          );
          providerCalled = true;
        }

        await expectLater(execute(), throwsA(same(admissionError)));
        expect(persisted, isFalse);
        expect(presented, isFalse);
        expect(latest, isFalse);
        expect(providerCalled, isFalse);
      },
    );

    test('cleanup failure cannot hide final admission failure', () async {
      final admissionError = StateError('injected final journal failure');

      await expectLater(
        NotificationReplyPreparedDispatchAdmission.run(
          admit: () async => throw admissionError,
          rollbackPreparedMessage: () async {
            throw StateError('injected cleanup failure');
          },
        ),
        throwsA(same(admissionError)),
      );
    });
  });

  group('notification reply journal compaction', () {
    test('blocking tombstones survive beyond active capacity and restart', () {
      var journal = NotificationReplyOperationJournal.empty();
      final identities = <NotificationReplyOperationIdentity>[];
      for (
        var index = 0;
        index < notificationReplyOperationJournalMaxActiveEntries + 64;
        index++
      ) {
        final identity = _identity(
          messageGuid: 'message-$index',
          text: 'reply-$index',
        );
        identities.add(identity);
        final attempt = _hash('terminal-attempt-$index');
        final begun = journal.begin(
          identity: identity,
          attemptId: attempt,
          processFingerprint: notificationReplyProcessFingerprint(1),
        );
        journal = begun.journal
            .transition(
              identity: identity,
              attemptId: attempt,
              from: NotificationReplyOperationState.reserved,
              to: NotificationReplyOperationState.executionStarted,
            )
            .transition(
              identity: identity,
              attemptId: attempt,
              from: NotificationReplyOperationState.executionStarted,
              to: NotificationReplyOperationState.terminal,
            );
      }

      expect(journal.activeLength, 0);
      expect(
        journal.blockingTombstoneLength,
        notificationReplyOperationJournalMaxActiveEntries + 64,
      );
      final restarted = NotificationReplyOperationJournal.decode(
        journal.encode(),
      );
      final oldest = identities.first;
      final duplicate = restarted.begin(
        identity: oldest,
        attemptId: _hash('duplicate-attempt'),
        processFingerprint: notificationReplyProcessFingerprint(2),
      );
      final fresh = restarted.begin(
        identity: _identity(messageGuid: 'fresh-message', text: 'fresh-reply'),
        attemptId: _hash('fresh-attempt'),
        processFingerprint: notificationReplyProcessFingerprint(2),
      );

      expect(
        duplicate.disposition,
        NotificationReplyBeginDisposition.alreadyTerminal,
      );
      expect(fresh.disposition, NotificationReplyBeginDisposition.accepted);
      expect(fresh.journal.activeLength, 1);
      expect(
        fresh.journal.blockingTombstoneLength,
        notificationReplyOperationJournalMaxActiveEntries + 64,
      );
    });

    test('capacity evicts only retryable pre-execution rejection', () {
      var journal = NotificationReplyOperationJournal.empty();
      final protected = _identity(
        messageGuid: 'execution-started-message',
        text: 'protected',
      );
      final protectedAttempt = _hash('protected-attempt');
      journal = journal
          .begin(
            identity: protected,
            attemptId: protectedAttempt,
            processFingerprint: notificationReplyProcessFingerprint(1),
          )
          .journal
          .transition(
            identity: protected,
            attemptId: protectedAttempt,
            from: NotificationReplyOperationState.reserved,
            to: NotificationReplyOperationState.executionStarted,
          );

      for (
        var index = 1;
        index < notificationReplyOperationJournalMaxActiveEntries;
        index++
      ) {
        final identity = _identity(
          messageGuid: 'rejected-message-$index',
          text: 'rejected-$index',
        );
        final attempt = _hash('rejected-attempt-$index');
        journal = journal
            .begin(
              identity: identity,
              attemptId: attempt,
              processFingerprint: notificationReplyProcessFingerprint(1),
            )
            .journal
            .transition(
              identity: identity,
              attemptId: attempt,
              from: NotificationReplyOperationState.reserved,
              to: NotificationReplyOperationState.preExecutionRejected,
            );
      }

      final fresh = _identity(
        messageGuid: 'new-message-at-capacity',
        text: 'new-reply',
      );
      final decision = journal.begin(
        identity: fresh,
        attemptId: _hash('new-attempt'),
        processFingerprint: notificationReplyProcessFingerprint(1),
      );

      expect(decision.disposition, NotificationReplyBeginDisposition.accepted);
      expect(
        decision.journal.recordFor(protected)?.state,
        NotificationReplyOperationState.executionStarted,
      );
      expect(decision.journal.recordFor(fresh), isNotNull);
      expect(
        decision.journal.activeLength,
        notificationReplyOperationJournalMaxActiveEntries,
      );
    });

    test('capacity fails closed when every active entry may have executed', () {
      var journal = NotificationReplyOperationJournal.empty();
      for (
        var index = 0;
        index < notificationReplyOperationJournalMaxActiveEntries;
        index++
      ) {
        final identity = _identity(
          messageGuid: 'active-message-$index',
          text: 'active-$index',
        );
        final attempt = _hash('active-attempt-$index');
        journal = journal
            .begin(
              identity: identity,
              attemptId: attempt,
              processFingerprint: notificationReplyProcessFingerprint(1),
            )
            .journal
            .transition(
              identity: identity,
              attemptId: attempt,
              from: NotificationReplyOperationState.reserved,
              to: NotificationReplyOperationState.executionStarted,
            );
      }

      expect(
        () => journal.begin(
          identity: _identity(
            messageGuid: 'blocked-message',
            text: 'blocked-reply',
          ),
          attemptId: _hash('blocked-attempt'),
          processFingerprint: notificationReplyProcessFingerprint(1),
        ),
        throwsStateError,
      );
    });

    test('legacy terminal record migrates to non-evicting tombstone', () {
      final identity = _identity();
      final attempt = _hash('legacy-attempt');
      final reserved = NotificationReplyOperationJournal.empty().begin(
        identity: identity,
        attemptId: attempt,
        processFingerprint: notificationReplyProcessFingerprint(1),
      );
      final terminalRecord = reserved.record
          .transition(NotificationReplyOperationState.executionStarted)
          .transition(NotificationReplyOperationState.terminal);
      final legacy = jsonEncode(<String, dynamic>{
        'schema': notificationReplyOperationJournalLegacySchema,
        'records': <Map<String, dynamic>>[terminalRecord.toJson()],
      });

      final migrated = NotificationReplyOperationJournal.decode(legacy);
      final restarted = NotificationReplyOperationJournal.decode(
        migrated.encode(),
      );
      final duplicate = restarted.begin(
        identity: identity,
        attemptId: _hash('later-attempt'),
        processFingerprint: notificationReplyProcessFingerprint(2),
      );

      expect(migrated.activeLength, 0);
      expect(migrated.blockingTombstoneLength, 1);
      expect(
        duplicate.disposition,
        NotificationReplyBeginDisposition.alreadyTerminal,
      );
      expect(migrated.encode(), isNot(contains('conversation_key_sha256')));
    });
  });
}
