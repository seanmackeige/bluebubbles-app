import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical unread physical provenance', () {
    final presentation = PhysicalConversationRef.fromStablePhysicalGuid('presentation-source');
    final sibling = PhysicalConversationRef.fromStablePhysicalGuid('unread-sibling-source');

    test('aggregate presentation sync never attributes sibling unread to presentation source', () {
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);

      expect(
        ledger.observePhysicalSnapshot(<PhysicalConversationRef, bool>{presentation: false, sibling: true}),
        isTrue,
      );
      final aggregatePresentationUnread = ledger.hasUnread;
      expect(aggregatePresentationUnread, isTrue);

      // The UI ChatState for the presentation member is now aggregate-true.
      // A later refresh must still consume the independent physical snapshot,
      // not that aggregate presentation bit.
      expect(
        ledger.observePhysicalSnapshot(<PhysicalConversationRef, bool>{presentation: false, sibling: true}),
        isFalse,
      );

      final plan = ledger.markReadPlan();
      expect(plan.entries.map((entry) => entry.source), <PhysicalConversationRef>[sibling]);
      expect(plan.entries.any((entry) => entry.source == presentation), isFalse);
    });

    test('physical snapshot requires every certified source exactly once', () {
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);
      expect(
        () => ledger.observePhysicalSnapshot(<PhysicalConversationRef, bool>{sibling: true}),
        throwsA(isA<StateError>()),
      );
    });

    test('partial restart retains missing-source unread and only updates available members', () {
      final original = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);
      original.observePhysicalSnapshot(
        <PhysicalConversationRef, bool>{presentation: false, sibling: true},
        eventWatermarks: <PhysicalConversationRef, int>{presentation: 10, sibling: 20},
      );

      final restored = LogicalUnreadLedger.fromJson(original.toJson());
      expect(
        restored.observeAvailablePhysicalSnapshot(
          <PhysicalConversationRef, bool>{presentation: false},
          eventWatermarks: <PhysicalConversationRef, int>{presentation: 10},
        ),
        isFalse,
      );

      expect(restored.certifiedSources, containsAll(<PhysicalConversationRef>[presentation, sibling]));
      expect(restored.observationFor(sibling)!.hasUnread, isTrue);
      expect(restored.observationFor(sibling)!.eventWatermark, 20);
      expect(restored.markReadPlan().entries.map((entry) => entry.source), <PhysicalConversationRef>[sibling]);
      expect(
        () => restored.observeAvailablePhysicalSnapshot(<PhysicalConversationRef, bool>{
          PhysicalConversationRef.fromStablePhysicalGuid('foreign-source'): true,
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('already-unread message watermark invalidates an in-flight mark-read plan', () {
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);
      ledger.observePhysicalSnapshot(
        <PhysicalConversationRef, bool>{presentation: true, sibling: false},
        eventWatermarks: <PhysicalConversationRef, int>{presentation: 100, sibling: 0},
      );
      final plan = ledger.markReadPlan();
      final planned = plan.entries.single;

      expect(
        ledger.observeUnreadEvent(source: presentation, eventWatermark: 101),
        LogicalUnreadObservationResult.advanced,
      );
      final advanced = ledger.observationFor(presentation)!;
      expect(advanced.hasUnread, isTrue);
      expect(advanced.revision, planned.observedRevision + 1);
      expect(advanced.eventWatermark, 101);

      final outcome = ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
        LogicalMarkReadReceipt.success(
          source: presentation,
          plannedRevision: planned.observedRevision,
          resultRevision: planned.observedRevision + 1,
        ),
      ], stalePlanAsPartial: true);

      expect(outcome, LogicalMarkReadOutcome.partial);
      expect(ledger.observationFor(presentation)!.hasUnread, isTrue);
      expect(ledger.observationFor(presentation)!.eventWatermark, 101);
    });

    test('replayed watermark cannot resurrect read state but a newer message can', () {
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);
      ledger.observePhysicalSnapshot(
        <PhysicalConversationRef, bool>{presentation: true, sibling: false},
        eventWatermarks: <PhysicalConversationRef, int>{presentation: 200, sibling: 0},
      );
      final plan = ledger.markReadPlan();
      final planned = plan.entries.single;
      expect(
        ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.success(
            source: presentation,
            plannedRevision: planned.observedRevision,
            resultRevision: planned.observedRevision + 1,
          ),
        ]),
        LogicalMarkReadOutcome.complete,
      );

      expect(
        ledger.observeUnreadEvent(source: presentation, eventWatermark: 200),
        LogicalUnreadObservationResult.unchanged,
      );
      expect(ledger.observationFor(presentation)!.hasUnread, isFalse);
      expect(
        ledger.observeUnreadEvent(source: presentation, eventWatermark: 201),
        LogicalUnreadObservationResult.advanced,
      );
      expect(ledger.observationFor(presentation)!.hasUnread, isTrue);
    });

    test('restart reconstruction retains watermark and ignores an older physical snapshot', () {
      final original = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);
      original.observePhysicalSnapshot(
        <PhysicalConversationRef, bool>{presentation: true, sibling: false},
        eventWatermarks: <PhysicalConversationRef, int>{presentation: 300, sibling: 10},
      );
      final restored = LogicalUnreadLedger.fromJson(original.toJson());

      expect(
        restored.observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{presentation: false, sibling: false},
          eventWatermarks: <PhysicalConversationRef, int>{presentation: 299, sibling: 10},
        ),
        isFalse,
      );
      expect(restored.observationFor(presentation)!.hasUnread, isTrue);
      expect(restored.observationFor(presentation)!.eventWatermark, 300);
    });

    test('partial acknowledgement retains only the failed exact source', () {
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[presentation, sibling]);
      ledger.observePhysicalSnapshot(<PhysicalConversationRef, bool>{presentation: true, sibling: true});
      final plan = ledger.markReadPlan();
      final presentationEntry = plan.entries.singleWhere((entry) => entry.source == presentation);
      final siblingEntry = plan.entries.singleWhere((entry) => entry.source == sibling);

      final outcome = ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
        LogicalMarkReadReceipt.success(
          source: presentation,
          plannedRevision: presentationEntry.observedRevision,
          resultRevision: presentationEntry.observedRevision + 1,
        ),
        LogicalMarkReadReceipt.failure(source: sibling, plannedRevision: siblingEntry.observedRevision),
      ]);

      expect(outcome, LogicalMarkReadOutcome.partial);
      expect(ledger.observationFor(presentation)!.hasUnread, isFalse);
      expect(ledger.observationFor(sibling)!.hasUnread, isTrue);
      expect(ledger.markReadPlan().entries.map((entry) => entry.source), <PhysicalConversationRef>[sibling]);
    });

    test('two certified conversations keep independent unread truth', () {
      final alphaId = LogicalConversationId.certified('unread-alpha');
      final betaId = LogicalConversationId.certified('unread-beta');
      final alphaPresentation = PhysicalConversationRef.fromStablePhysicalGuid('alpha-presentation');
      final alphaSibling = PhysicalConversationRef.fromStablePhysicalGuid('alpha-sibling');
      final betaPresentation = PhysicalConversationRef.fromStablePhysicalGuid('beta-presentation');
      final betaSibling = PhysicalConversationRef.fromStablePhysicalGuid('beta-sibling');
      final alphaLedger =
          LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[alphaPresentation, alphaSibling])
            ..observePhysicalSnapshot(
              <PhysicalConversationRef, bool>{alphaPresentation: true, alphaSibling: false},
              eventWatermarks: <PhysicalConversationRef, int>{alphaPresentation: 10, alphaSibling: 0},
            );
      final betaLedger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[betaPresentation, betaSibling])
        ..observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{betaPresentation: false, betaSibling: true},
          eventWatermarks: <PhysicalConversationRef, int>{betaPresentation: 0, betaSibling: 20},
        );
      final alpha = LogicalUnreadConversationState(logicalId: alphaId, ledger: alphaLedger);
      final beta = LogicalUnreadConversationState(logicalId: betaId, ledger: betaLedger);
      final store = LogicalUnreadConversationStore()
        ..put(beta)
        ..put(alpha);

      expect(store.unreadConversationCount, 2);
      expect(store.states.map((state) => state.logicalId), <LogicalConversationId>[alphaId, betaId]..sort());
      expect(alpha.messageWatermarkFor(alphaPresentation), 10);
      expect(beta.messageWatermarkFor(betaSibling), 20);

      final alphaPlan = alphaLedger.markReadPlan();
      final alphaEntry = alphaPlan.entries.single;
      expect(
        alphaLedger.applyMarkReadReceipts(alphaPlan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.success(
            source: alphaPresentation,
            plannedRevision: alphaEntry.observedRevision,
            resultRevision: alphaEntry.observedRevision + 1,
          ),
        ]),
        LogicalMarkReadOutcome.complete,
      );

      expect(store.unreadConversationCount, 1);
      expect(betaLedger.observationFor(betaSibling)!.hasUnread, isTrue);
      expect(beta.messageWatermarkFor(betaSibling), 20);
    });

    test('interleaved mark-read and new-message race is isolated per logical ID', () {
      final alphaSource = PhysicalConversationRef.fromStablePhysicalGuid('race-alpha-source');
      final betaSource = PhysicalConversationRef.fromStablePhysicalGuid('race-beta-source');
      final alphaLedger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[alphaSource])
        ..observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{alphaSource: true},
          eventWatermarks: <PhysicalConversationRef, int>{alphaSource: 100},
        );
      final betaLedger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[betaSource])
        ..observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{betaSource: true},
          eventWatermarks: <PhysicalConversationRef, int>{betaSource: 200},
        );
      final alpha = LogicalUnreadConversationState(
        logicalId: LogicalConversationId.certified('race-alpha'),
        ledger: alphaLedger,
      );
      final beta = LogicalUnreadConversationState(
        logicalId: LogicalConversationId.certified('race-beta'),
        ledger: betaLedger,
      );
      final store = LogicalUnreadConversationStore()
        ..put(alpha)
        ..put(beta);
      final alphaPlan = alphaLedger.markReadPlan();
      final betaPlan = betaLedger.markReadPlan();
      final alphaPlanned = alphaPlan.entries.single;
      final betaPlanned = betaPlan.entries.single;

      alpha.beginMarkRead();
      beta.beginMarkRead();
      expect(
        alpha.observeUnreadEvent(source: alphaSource, observedWatermark: 101),
        LogicalUnreadObservationResult.advanced,
      );
      final alphaOutcome = alphaLedger.applyMarkReadReceipts(alphaPlan, <LogicalMarkReadReceipt>[
        LogicalMarkReadReceipt.success(
          source: alphaSource,
          plannedRevision: alphaPlanned.observedRevision,
          resultRevision: alphaPlanned.observedRevision + 1,
        ),
      ], stalePlanAsPartial: true);
      final betaOutcome = betaLedger.applyMarkReadReceipts(betaPlan, <LogicalMarkReadReceipt>[
        LogicalMarkReadReceipt.success(
          source: betaSource,
          plannedRevision: betaPlanned.observedRevision,
          resultRevision: betaPlanned.observedRevision + 1,
        ),
      ]);
      alpha.lastOutcome = alphaOutcome;
      alpha.syncPending = true;
      beta.lastOutcome = betaOutcome;
      beta.syncPending = false;
      alpha.endMarkRead();
      beta.endMarkRead();

      expect(alphaOutcome, LogicalMarkReadOutcome.partial);
      expect(alpha.pendingWatermarkFor(alphaSource), 101);
      expect(alphaLedger.observationFor(alphaSource)!.hasUnread, isTrue);
      expect(betaOutcome, LogicalMarkReadOutcome.complete);
      expect(beta.hasPendingWatermarks, isFalse);
      expect(betaLedger.observationFor(betaSource)!.hasUnread, isFalse);
      expect(store.anySyncPending, isTrue);
      expect(store.unreadConversationCount, 1);

      final restored = LogicalUnreadConversationState(
        logicalId: alpha.logicalId,
        ledger: LogicalUnreadLedger.fromJson(alphaLedger.toJson()),
        syncPending: true,
      );
      expect(restored.messageWatermarkFor(alphaSource), 101);
      expect(restored.pendingWatermarkFor(alphaSource), 101);
    });

    test('provider read confirmation closes the admitted receipt race exactly once', () {
      final source = PhysicalConversationRef.fromStablePhysicalGuid('provider-confirmed-source');
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[source])
        ..observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{source: true},
          eventWatermarks: <PhysicalConversationRef, int>{source: 400},
        );
      final state = LogicalUnreadConversationState(
        logicalId: LogicalConversationId.certified('provider-confirmed'),
        ledger: ledger,
      );
      final plan = ledger.markReadPlan();
      final planned = plan.entries.single;

      state.beginMarkRead(plan);
      expect(
        state.observeProviderReadStatus(source: source, hasUnread: false),
        LogicalUnreadObservationResult.advanced,
      );
      final confirmed = ledger.observationFor(source)!;
      expect(
        ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.success(
            source: source,
            plannedRevision: planned.observedRevision,
            resultRevision: confirmed.revision,
          ),
        ], stalePlanAsPartial: true),
        LogicalMarkReadOutcome.complete,
      );
      state.endMarkRead();
      expect(ledger.hasUnread, isFalse);
      expect(ledger.observationFor(source)!.eventWatermark, 400);
    });

    test('provider confirmation cannot acknowledge an inbound after its admitted watermark', () {
      final source = PhysicalConversationRef.fromStablePhysicalGuid('provider-stale-confirmation-source');
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[source])
        ..observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{source: true},
          eventWatermarks: <PhysicalConversationRef, int>{source: 100},
        );
      final state = LogicalUnreadConversationState(
        logicalId: LogicalConversationId.certified('provider-stale-confirmation'),
        ledger: ledger,
      );
      final plan = ledger.markReadPlan();
      final planned = plan.entries.single;

      state.beginMarkRead(plan);
      expect(state.observeUnreadEvent(source: source, observedWatermark: 101), LogicalUnreadObservationResult.advanced);
      expect(
        state.observeProviderReadStatus(source: source, hasUnread: false),
        LogicalUnreadObservationResult.staleIgnored,
      );
      expect(
        ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.success(
            source: source,
            plannedRevision: planned.observedRevision,
            resultRevision: planned.observedRevision + 1,
          ),
        ], stalePlanAsPartial: true),
        LogicalMarkReadOutcome.partial,
      );
      state.endMarkRead();

      // A duplicated/delayed provider event after execution retains the same
      // bound: it has no evidence that it read through message watermark 101.
      expect(
        state.observeProviderReadStatus(source: source, hasUnread: false),
        LogicalUnreadObservationResult.staleIgnored,
      );
      expect(ledger.observationFor(source)!.hasUnread, isTrue);
      expect(ledger.observationFor(source)!.eventWatermark, 101);
      expect(state.pendingWatermarkFor(source), 101);
      expect(state.syncPending, isTrue);
    });

    test('delayed provider confirmation cannot clear an inbound after mark-read completed', () {
      final source = PhysicalConversationRef.fromStablePhysicalGuid('post-plan-confirmation-source');
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[source])
        ..observePhysicalSnapshot(
          <PhysicalConversationRef, bool>{source: true},
          eventWatermarks: <PhysicalConversationRef, int>{source: 100},
        );
      final state = LogicalUnreadConversationState(
        logicalId: LogicalConversationId.certified('post-plan-confirmation'),
        ledger: ledger,
      );
      final plan = ledger.markReadPlan();
      final planned = plan.entries.single;

      state.beginMarkRead(plan);
      expect(
        state.observeProviderReadStatus(source: source, hasUnread: false),
        LogicalUnreadObservationResult.advanced,
      );
      final confirmed = ledger.observationFor(source)!;
      expect(
        ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.success(
            source: source,
            plannedRevision: planned.observedRevision,
            resultRevision: confirmed.revision,
          ),
        ], stalePlanAsPartial: true),
        LogicalMarkReadOutcome.complete,
      );
      state.endMarkRead();

      expect(state.observeUnreadEvent(source: source, observedWatermark: 101), LogicalUnreadObservationResult.advanced);
      expect(state.pendingWatermarkFor(source), 101);
      expect(
        state.observeProviderReadStatus(source: source, hasUnread: false),
        LogicalUnreadObservationResult.staleIgnored,
      );
      expect(ledger.observationFor(source)!.hasUnread, isTrue);
      expect(ledger.observationFor(source)!.eventWatermark, 101);
      expect(state.syncPending, isTrue);
    });

    test('per-logical durable snapshots remain FIFO across delayed writes and restart', () async {
      final source = PhysicalConversationRef.fromStablePhysicalGuid('serialized-ledger-source');
      final older = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[source])
        ..observeUnreadEvent(source: source, eventWatermark: 100);
      final newer = LogicalUnreadLedger.fromJson(older.toJson())
        ..observeUnreadEvent(source: source, eventWatermark: 101);
      final executor = LogicalKeyedSerialExecutor();
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      String? durableJson;

      final first = executor.run<void>('serialized-logical', () async {
        firstStarted.complete();
        await releaseFirst.future;
        durableJson = jsonEncode(older.toJson());
      });
      await firstStarted.future;
      final second = executor.run<void>('serialized-logical', () async {
        durableJson = jsonEncode(newer.toJson());
      });
      releaseFirst.complete();
      await Future.wait(<Future<void>>[first, second]);

      final restored = LogicalUnreadLedger.fromJson((jsonDecode(durableJson!) as Map).cast<String, dynamic>());
      expect(restored.observationFor(source)!.eventWatermark, 101);
      expect(restored.observationFor(source)!.hasUnread, isTrue);
      expect(executor.activeKeyCount, 0);
    });

    test('same logical mark-read callers coalesce while other IDs remain independent', () async {
      final coalescer = LogicalOperationCoalescer<int>();
      final alphaGate = Completer<int>();
      var alphaExecutions = 0;
      var betaExecutions = 0;

      final alphaFirst = coalescer.run('logical-alpha', () {
        alphaExecutions += 1;
        return alphaGate.future;
      });
      final alphaSecond = coalescer.run('logical-alpha', () async {
        alphaExecutions += 1;
        return 99;
      });
      final beta = coalescer.run('logical-beta', () async {
        betaExecutions += 1;
        return 2;
      });

      expect(identical(alphaFirst, alphaSecond), isTrue);
      expect(await beta, 2);
      expect(betaExecutions, 1);
      expect(alphaExecutions, 1);
      alphaGate.complete(1);
      expect(await alphaFirst, 1);
      expect(await alphaSecond, 1);
      await Future<void>.delayed(Duration.zero);
      expect(coalescer.activeOperationCount, 0);
    });
  });
}
