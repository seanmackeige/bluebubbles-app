import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';

/// Diagnostics-only state for a certified logical conversation.
///
/// This projection intentionally carries no provider coordinates, participant
/// values, or mutation capability.
enum LogicalConversationHealthState { healthy, reconciling, readSyncPending, indexPending, writeBlocked, degraded }

enum LogicalGenerationHealth { current, reconciling, unproven }

enum LogicalWriterHealthReason {
  ready,
  evidenceNotChecked,
  reconciling,
  noCurrentWriter,
  multipleWriters,
  invariantBlocked,
  transportUnavailable,
  routeUnproven,
}

enum LogicalProviderRevisionHealth { current, unobserved, stale }

enum LogicalDraftHealth { none, safe, staleRevalidation }

enum LogicalIndexHealth { indexed, pending }

class LogicalConversationHealthEvidence {
  const LogicalConversationHealthEvidence({
    required this.snapshot,
    required this.availableMemberCount,
    required this.routeStage,
    required this.generation,
    required this.writer,
    required this.providerRevision,
    required this.readSyncPending,
    required this.notificationReady,
    required this.draft,
    required this.relationshipCount,
    required this.relationshipIndexComplete,
    required this.searchIndexComplete,
    required this.mediaIndexComplete,
  });

  final LogicalConversationSnapshot snapshot;
  final int availableMemberCount;
  final LogicalRouteRuntimeStage routeStage;
  final LogicalGenerationHealth generation;
  final LogicalWriterHealthReason writer;
  final LogicalProviderRevisionHealth providerRevision;
  final bool readSyncPending;
  final bool notificationReady;
  final LogicalDraftHealth draft;
  final int relationshipCount;
  final bool relationshipIndexComplete;
  final bool searchIndexComplete;
  final bool mediaIndexComplete;
}

class LogicalConversationHealthProjection {
  LogicalConversationHealthProjection._({
    required this.state,
    required this.memberCount,
    required this.availableMemberCount,
    required this.generation,
    required this.writer,
    required this.providerRevision,
    required this.unreadSourceCount,
    required this.sourceReadSynchronized,
    required this.notificationReady,
    required this.draft,
    required this.relationshipCount,
    required this.relationshipIndex,
    required this.searchResultCount,
    required this.searchIndex,
    required this.mediaItemCount,
    required this.mediaIndex,
  });

  factory LogicalConversationHealthProjection.derive(LogicalConversationHealthEvidence evidence) {
    final snapshot = evidence.snapshot;
    if (!snapshot.logicalId.isCertified) {
      throw StateError('LOGICAL_HEALTH_REQUIRES_CERTIFIED_IDENTITY');
    }
    if (evidence.availableMemberCount < 0 || evidence.availableMemberCount > snapshot.members.length) {
      throw ArgumentError.value(
        evidence.availableMemberCount,
        'availableMemberCount',
        'must be within the certified member set',
      );
    }
    if (evidence.relationshipCount < 0) {
      throw ArgumentError.value(evidence.relationshipCount, 'relationshipCount', 'must not be negative');
    }

    final ledger = snapshot.unreadLedger;
    final unreadSourceCount = ledger.observations.where((observation) => observation.hasUnread).length;
    final sourceReadSynchronized = !evidence.readSyncPending && ledger.observations.length == snapshot.members.length;
    final relationshipIndex = evidence.relationshipIndexComplete
        ? LogicalIndexHealth.indexed
        : LogicalIndexHealth.pending;
    final searchIndex = evidence.searchIndexComplete ? LogicalIndexHealth.indexed : LogicalIndexHealth.pending;
    final mediaIndex = evidence.mediaIndexComplete ? LogicalIndexHealth.indexed : LogicalIndexHealth.pending;

    final degraded =
        snapshot.health == LogicalConversationHealth.degraded ||
        snapshot.health == LogicalConversationHealth.conflict ||
        evidence.availableMemberCount != snapshot.members.length ||
        evidence.providerRevision == LogicalProviderRevisionHealth.stale ||
        !evidence.notificationReady;
    final reconciling =
        evidence.routeStage == LogicalRouteRuntimeStage.unchecked ||
        evidence.routeStage == LogicalRouteRuntimeStage.checking ||
        evidence.generation == LogicalGenerationHealth.reconciling;
    final readSyncPending =
        evidence.readSyncPending ||
        snapshot.health == LogicalConversationHealth.partialReadAcknowledgement ||
        !sourceReadSynchronized;
    final writeBlocked =
        evidence.writer != LogicalWriterHealthReason.ready || snapshot.health == LogicalConversationHealth.readOnly;
    final indexPending =
        relationshipIndex == LogicalIndexHealth.pending ||
        searchIndex == LogicalIndexHealth.pending ||
        mediaIndex == LogicalIndexHealth.pending;

    final state = degraded
        ? LogicalConversationHealthState.degraded
        : reconciling
        ? LogicalConversationHealthState.reconciling
        : readSyncPending
        ? LogicalConversationHealthState.readSyncPending
        : writeBlocked
        ? LogicalConversationHealthState.writeBlocked
        : indexPending
        ? LogicalConversationHealthState.indexPending
        : LogicalConversationHealthState.healthy;

    return LogicalConversationHealthProjection._(
      state: state,
      memberCount: snapshot.members.length,
      availableMemberCount: evidence.availableMemberCount,
      generation: evidence.generation,
      writer: evidence.writer,
      providerRevision: evidence.providerRevision,
      unreadSourceCount: unreadSourceCount,
      sourceReadSynchronized: sourceReadSynchronized,
      notificationReady: evidence.notificationReady,
      draft: evidence.draft,
      relationshipCount: evidence.relationshipCount,
      relationshipIndex: relationshipIndex,
      searchResultCount: snapshot.searchResults.length,
      searchIndex: searchIndex,
      mediaItemCount: snapshot.mediaItems.length,
      mediaIndex: mediaIndex,
    );
  }

  final LogicalConversationHealthState state;
  final int memberCount;
  final int availableMemberCount;
  final LogicalGenerationHealth generation;
  final LogicalWriterHealthReason writer;
  final LogicalProviderRevisionHealth providerRevision;
  final int unreadSourceCount;
  final bool sourceReadSynchronized;
  final bool notificationReady;
  final LogicalDraftHealth draft;
  final int relationshipCount;
  final LogicalIndexHealth relationshipIndex;
  final int searchResultCount;
  final LogicalIndexHealth searchIndex;
  final int mediaItemCount;
  final LogicalIndexHealth mediaIndex;

  /// Public-safe, bounded diagnostics for presentation and tests.
  Map<String, Object> get publicSafeFields => <String, Object>{
    'state': state.name,
    'member_count': memberCount,
    'available_member_count': availableMemberCount,
    'generation': generation.name,
    'writer': writer.name,
    'provider_revision': providerRevision.name,
    'unread_source_count': unreadSourceCount,
    'source_read_synchronized': sourceReadSynchronized,
    'notification_ready': notificationReady,
    'draft': draft.name,
    'relationship_count': relationshipCount,
    'relationship_index': relationshipIndex.name,
    'search_result_count': searchResultCount,
    'search_index': searchIndex.name,
    'media_item_count': mediaItemCount,
    'media_index': mediaIndex.name,
  };
}
