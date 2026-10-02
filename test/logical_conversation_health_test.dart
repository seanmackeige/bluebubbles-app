import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_health.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical conversation health projection', () {
    test('healthy requires synchronized sources, a ready writer, and complete indexes', () {
      final projection = _derive();

      expect(projection.state, LogicalConversationHealthState.healthy);
      expect(projection.memberCount, 2);
      expect(projection.availableMemberCount, 2);
      expect(projection.unreadSourceCount, 1);
      expect(projection.sourceReadSynchronized, isTrue);
      expect(projection.relationshipIndex, LogicalIndexHealth.indexed);
      expect(projection.searchIndex, LogicalIndexHealth.indexed);
      expect(projection.mediaIndex, LogicalIndexHealth.indexed);
    });

    test('state priority is fail closed and deterministic', () {
      expect(_derive(routeStage: LogicalRouteRuntimeStage.checking).state, LogicalConversationHealthState.reconciling);
      expect(_derive(readSyncPending: true).state, LogicalConversationHealthState.readSyncPending);
      expect(
        _derive(writer: LogicalWriterHealthReason.noCurrentWriter).state,
        LogicalConversationHealthState.writeBlocked,
      );
      expect(_derive(searchIndexComplete: false).state, LogicalConversationHealthState.indexPending);
      expect(
        _derive(
          availableMemberCount: 1,
          routeStage: LogicalRouteRuntimeStage.checking,
          readSyncPending: true,
          writer: LogicalWriterHealthReason.noCurrentWriter,
          searchIndexComplete: false,
        ).state,
        LogicalConversationHealthState.degraded,
      );
    });

    test('stale provider revision and notification failure degrade independently', () {
      expect(
        _derive(providerRevision: LogicalProviderRevisionHealth.stale).state,
        LogicalConversationHealthState.degraded,
      );
      expect(_derive(notificationReady: false).state, LogicalConversationHealthState.degraded);
    });

    test('incomplete unread observations are read-sync pending', () {
      final projection = LogicalConversationHealthProjection.derive(
        _evidence(snapshot: _snapshot(includeSecondObservation: false)),
      );

      expect(projection.sourceReadSynchronized, isFalse);
      expect(projection.state, LogicalConversationHealthState.readSyncPending);
    });

    test('public-safe fields contain no logical, physical, or participant identity', () {
      final encoded = jsonEncode(_derive(draft: LogicalDraftHealth.staleRevalidation).publicSafeFields);

      expect(encoded, isNot(contains('source-alpha')));
      expect(encoded, isNot(contains('source-beta')));
      expect(encoded, isNot(contains('certified-health')));
      expect(encoded.toLowerCase(), isNot(contains('guid')));
      expect(encoded.toLowerCase(), isNot(contains('rowid')));
      expect(encoded, contains('staleRevalidation'));
    });

    test('ordinary identity and impossible cardinality fail closed', () {
      final ordinary = _snapshot(logicalId: LogicalConversationId.ordinarySingleton('ordinary-source'));
      expect(
        () => LogicalConversationHealthProjection.derive(_evidence(snapshot: ordinary)),
        throwsA(isA<StateError>()),
      );
      expect(() => _derive(availableMemberCount: 3), throwsArgumentError);
    });
  });
}

LogicalConversationHealthProjection _derive({
  int availableMemberCount = 2,
  LogicalRouteRuntimeStage routeStage = LogicalRouteRuntimeStage.qualified,
  LogicalGenerationHealth generation = LogicalGenerationHealth.current,
  LogicalWriterHealthReason writer = LogicalWriterHealthReason.ready,
  LogicalProviderRevisionHealth providerRevision = LogicalProviderRevisionHealth.current,
  bool readSyncPending = false,
  bool notificationReady = true,
  LogicalDraftHealth draft = LogicalDraftHealth.safe,
  bool relationshipIndexComplete = true,
  bool searchIndexComplete = true,
  bool mediaIndexComplete = true,
}) {
  return LogicalConversationHealthProjection.derive(
    _evidence(
      availableMemberCount: availableMemberCount,
      routeStage: routeStage,
      generation: generation,
      writer: writer,
      providerRevision: providerRevision,
      readSyncPending: readSyncPending,
      notificationReady: notificationReady,
      draft: draft,
      relationshipIndexComplete: relationshipIndexComplete,
      searchIndexComplete: searchIndexComplete,
      mediaIndexComplete: mediaIndexComplete,
    ),
  );
}

LogicalConversationHealthEvidence _evidence({
  LogicalConversationSnapshot? snapshot,
  int availableMemberCount = 2,
  LogicalRouteRuntimeStage routeStage = LogicalRouteRuntimeStage.qualified,
  LogicalGenerationHealth generation = LogicalGenerationHealth.current,
  LogicalWriterHealthReason writer = LogicalWriterHealthReason.ready,
  LogicalProviderRevisionHealth providerRevision = LogicalProviderRevisionHealth.current,
  bool readSyncPending = false,
  bool notificationReady = true,
  LogicalDraftHealth draft = LogicalDraftHealth.safe,
  bool relationshipIndexComplete = true,
  bool searchIndexComplete = true,
  bool mediaIndexComplete = true,
}) {
  return LogicalConversationHealthEvidence(
    snapshot: snapshot ?? _snapshot(),
    availableMemberCount: availableMemberCount,
    routeStage: routeStage,
    generation: generation,
    writer: writer,
    providerRevision: providerRevision,
    readSyncPending: readSyncPending,
    notificationReady: notificationReady,
    draft: draft,
    relationshipCount: 3,
    relationshipIndexComplete: relationshipIndexComplete,
    searchIndexComplete: searchIndexComplete,
    mediaIndexComplete: mediaIndexComplete,
  );
}

LogicalConversationSnapshot _snapshot({LogicalConversationId? logicalId, bool includeSecondObservation = true}) {
  final identity = logicalId ?? LogicalConversationId.certified('certified-health');
  final sourceA = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
  final sourceB = PhysicalConversationRef.fromStablePhysicalGuid('source-beta');
  final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[sourceA, sourceB])
    ..observe(LogicalUnreadObservation(source: sourceA, revision: 1, hasUnread: true));
  if (includeSecondObservation) {
    ledger.observe(LogicalUnreadObservation(source: sourceB, revision: 1, hasUnread: false));
  }
  return LogicalConversationSnapshot(
    logicalId: identity,
    members: <PhysicalConversationRef>[sourceA, sourceB],
    health: LogicalConversationHealth.healthy,
    unreadLedger: ledger,
    searchResults: const <LogicalSearchResult>[],
    mediaItems: const <LogicalMediaItem>[],
    revision: 1,
  );
}
