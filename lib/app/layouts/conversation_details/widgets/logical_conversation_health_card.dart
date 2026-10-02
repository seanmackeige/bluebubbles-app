import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_application_snapshot.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_health.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Read-only, public-safe diagnostics for a certified logical conversation.
/// It deliberately exposes no source GUID/ROWID, participant value, or action.
class LogicalConversationHealthCard extends StatelessWidget {
  const LogicalConversationHealthCard({super.key, required this.chat, this.snapshot});

  final Chat chat;

  /// Optional immutable evidence view for tests and callers that already own a
  /// registry snapshot. The ordinary details surface derives the same model
  /// from the current certified registry without adding mutation capability.
  final LogicalConversationApplicationSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final application = snapshot ?? _applicationSnapshot();
      if (application == null) return const SizedBox.shrink();
      final projection = application.health;
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: ExpansionTile(
          leading: Icon(Icons.health_and_safety_outlined, color: _stateColor(context, projection.state)),
          title: const Text('Logical conversation health'),
          subtitle: Text(_stateLabel(projection.state)),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: <Widget>[
            _row('Certified members', '${projection.availableMemberCount}/${projection.memberCount} available'),
            _row('Presentation', application.presentationAvailable ? 'Available' : 'Unavailable'),
            _row('Latest message', _latestMessageLabel(application.latestMessage)),
            _row('Current generation', _generationLabel(projection.generation)),
            _row('Writer', _writerLabel(projection.writer)),
            _row('Provider revision', _providerRevisionLabel(projection.providerRevision)),
            _row(
              'Unread/source sync',
              projection.sourceReadSynchronized
                  ? 'Synchronized (${projection.unreadSourceCount} unread)'
                  : 'Pending (${projection.unreadSourceCount} unread)',
            ),
            _row('Notifications', projection.notificationReady ? 'Healthy' : 'Degraded'),
            _row('Draft', _draftLabel(projection.draft)),
            _row('Settings', _settingsLabel(application.settings)),
            _row('Relationships', _indexLabel(projection.relationshipIndex, projection.relationshipCount)),
            _row('Search', _indexLabel(projection.searchIndex, projection.searchResultCount)),
            _row('Media', _indexLabel(projection.mediaIndex, projection.mediaItemCount)),
          ],
        ),
      );
    });
  }

  LogicalConversationApplicationSnapshot? _applicationSnapshot() {
    final identity = ChatsSvc.conversationIdentityFor(chat);
    if (!identity.isCertified || !ChatsSvc.isLogicalConversation(chat)) return null;
    final entry = ChatsSvc.logicalConversationRegistry.entryForLogicalId(identity);
    if (entry == null) return null;

    final boundSources = <({Chat source, LogicalConversationRegistryMember member})>[];
    final availableMembers = <PhysicalConversationRef>{};
    for (final source in ChatsSvc.logicalSourceChatsFor(chat)) {
      final member = entry.memberForSourceRowId(source.originalROWID);
      final runtimeRef = PhysicalConversationRef.fromStablePhysicalGuid(source.guid);
      if (member == null || member.runtimePhysicalRef != runtimeRef || !availableMembers.add(member.certifiedRef)) {
        continue;
      }
      boundSources.add((source: source, member: member));
    }

    final unreadLedger =
        ChatsSvc.logicalUnreadLedgerFor(chat) ?? LogicalUnreadLedger(certifiedSources: entry.certifiedMemberRefs);

    var latestMessage = const LogicalLatestMessageSnapshot.none();
    final latestCandidates = <({Message message, LogicalConversationRegistryMember member})>[];
    for (final binding in boundSources) {
      final message = binding.source.dbLatestMessage.target;
      if (message?.guid != null && message?.dateCreated != null) {
        latestCandidates.add((message: message!, member: binding.member));
      }
    }
    latestCandidates.sort((left, right) => compareLogicalMessagesDescending(left.message, right.message));
    if (latestCandidates.isNotEmpty) {
      final latest = latestCandidates.first;
      latestMessage = LogicalLatestMessageSnapshot.observed(
        logicalId: identity,
        source: latest.member.certifiedRef,
        stableMessageId: latest.message.guid!,
        occurredAtEpochMicroseconds: latest.message.dateCreated!.microsecondsSinceEpoch,
      );
    }

    var routeStage = LogicalRouteRuntimeStage.routeNotProven;
    var generation = LogicalGenerationHealth.unproven;
    var writer = LogicalWriterHealthReason.routeUnproven;
    var providerRevision = LogicalProviderRevisionHealth.unobserved;
    var relationshipCount = 0;
    var relationshipIndexComplete = false;
    var revision = 0;
    final isBuild99WriterConversation = ChatsSvc.hasBuild99WriterCapability(chat);
    final currentRevision = isBuild99WriterConversation ? ChatsSvc.currentLogicalAuthorityRevision : null;
    if (isBuild99WriterConversation) {
      final status = ChatsSvc.logicalRouteRuntimeStatus.value;
      routeStage = status.stage;
      generation = _generationHealth(status);
      writer = _writerHealth(status);
      providerRevision = status.authorityRevision == null && currentRevision == null
          ? LogicalProviderRevisionHealth.unobserved
          : currentRevision != null &&
                status.authorityRevision == currentRevision.authorityRevision &&
                status.authorityEpoch == currentRevision.epoch
          ? LogicalProviderRevisionHealth.current
          : LogicalProviderRevisionHealth.stale;
      final relationshipEdges = status.diagnostics?['member_edges'];
      relationshipCount = relationshipEdges is List ? relationshipEdges.length : 0;
      relationshipIndexComplete = status.hasEvaluated && status.diagnostics != null;
      revision = currentRevision?.epoch ?? status.authorityEpoch ?? 0;
    }

    // Reading the aggregate observable keeps the diagnostics reactive. Truth
    // remains scoped to this exact logical identity, never the compatibility
    // aggregate used by older UI call sites.
    final compatibilityReadSyncPending = ChatsSvc.logicalReadSyncPending.value;
    final readSyncPending =
        ChatsSvc.logicalReadSyncPendingFor(chat) ||
        PrefsSvc.messaging.loadLogicalReadSyncPending(identity.value) ||
        (compatibilityReadSyncPending && ChatsSvc.logicalReadSyncPendingFor(chat));
    final draft = ChatsSvc.loadLogicalDraft(chat);
    final draftHealth = draft == null
        ? LogicalDraftHealth.none
        : currentRevision != null && currentRevision.matchesDraft(draft)
        ? LogicalDraftHealth.safe
        : LogicalDraftHealth.staleRevalidation;
    final draftSnapshot = draft == null
        ? const LogicalDraftApplicationSnapshot.none()
        : LogicalDraftApplicationSnapshot.fromDraft(draft, health: draftHealth);
    final settings = ChatsSvc.logicalSettingsFor(chat);
    final settingsSnapshot = settings == null
        ? const LogicalConversationSettingsSnapshot.unavailable()
        : LogicalConversationSettingsSnapshot.fromSettings(settings);
    final notificationIdentity = LogicalNotificationIdentity.fromLogicalId(identity);
    final directProjectionSourcesComplete = availableMembers.length == entry.certifiedMemberRefs.length;

    return LogicalConversationApplicationSnapshot.build(
      registryEntry: entry,
      availableMembers: availableMembers,
      unreadLedger: unreadLedger,
      latestMessage: latestMessage,
      routeStage: routeStage,
      generation: generation,
      writer: writer,
      providerRevision: providerRevision,
      readSyncPending: readSyncPending,
      notificationReady: notificationIdentity.stableKey.isNotEmpty && notificationIdentity.androidId < 0,
      draft: draftSnapshot,
      settings: settingsSnapshot,
      relationshipCount: relationshipCount,
      relationshipIndexComplete: relationshipIndexComplete,
      // Search and media are direct source-backed projections, not independent
      // mutable indexes. They are ready exactly when every certified source is
      // currently bound; partial binding remains visibly pending.
      searchResults: const <LogicalSearchResult>[],
      searchIndexComplete: directProjectionSourcesComplete,
      mediaItems: const <LogicalMediaItem>[],
      mediaIndexComplete: directProjectionSourcesComplete,
      revision: revision,
    );
  }

  LogicalGenerationHealth _generationHealth(LogicalRouteRuntimeStatus status) {
    if (status.stage == LogicalRouteRuntimeStage.unchecked || status.stage == LogicalRouteRuntimeStage.checking) {
      return LogicalGenerationHealth.reconciling;
    }
    return status.diagnostics?['current_generation_id'] is String
        ? LogicalGenerationHealth.current
        : LogicalGenerationHealth.unproven;
  }

  LogicalWriterHealthReason _writerHealth(LogicalRouteRuntimeStatus status) => switch (status.stage) {
    LogicalRouteRuntimeStage.unchecked => LogicalWriterHealthReason.evidenceNotChecked,
    LogicalRouteRuntimeStage.checking => LogicalWriterHealthReason.reconciling,
    LogicalRouteRuntimeStage.qualified when status.sendDisposition == LogicalTransportSendDisposition.blocked =>
      LogicalWriterHealthReason.transportUnavailable,
    LogicalRouteRuntimeStage.qualified => LogicalWriterHealthReason.ready,
    LogicalRouteRuntimeStage.routeNotProven when status.authorityState == 'SEND_BLOCKED_NO_CURRENT_WRITER' =>
      LogicalWriterHealthReason.noCurrentWriter,
    LogicalRouteRuntimeStage.routeNotProven when status.authorityState == 'SEND_BLOCKED_TRUE_MULTI_WRITER_AMBIGUITY' =>
      LogicalWriterHealthReason.multipleWriters,
    LogicalRouteRuntimeStage.routeNotProven when status.authorityState == 'SEND_BLOCKED_INVARIANT' =>
      LogicalWriterHealthReason.invariantBlocked,
    LogicalRouteRuntimeStage.routeNotProven => LogicalWriterHealthReason.routeUnproven,
  };

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: Text(label)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );

  String _stateLabel(LogicalConversationHealthState state) => switch (state) {
    LogicalConversationHealthState.healthy => 'HEALTHY',
    LogicalConversationHealthState.reconciling => 'RECONCILING',
    LogicalConversationHealthState.readSyncPending => 'READ_SYNC_PENDING',
    LogicalConversationHealthState.indexPending => 'INDEX_PENDING',
    LogicalConversationHealthState.writeBlocked => 'WRITE_BLOCKED',
    LogicalConversationHealthState.degraded => 'DEGRADED',
  };

  String _latestMessageLabel(LogicalLatestMessageSnapshot latest) => switch (latest.state) {
    LogicalLatestMessageState.none => 'Not observed',
    LogicalLatestMessageState.observed => 'Observed',
  };

  String _generationLabel(LogicalGenerationHealth value) => switch (value) {
    LogicalGenerationHealth.current => 'Current evidence established',
    LogicalGenerationHealth.reconciling => 'Reconciling',
    LogicalGenerationHealth.unproven => 'Not proven',
  };

  String _writerLabel(LogicalWriterHealthReason value) => switch (value) {
    LogicalWriterHealthReason.ready => 'Ready',
    LogicalWriterHealthReason.evidenceNotChecked => 'Evidence not checked',
    LogicalWriterHealthReason.reconciling => 'Reconciling',
    LogicalWriterHealthReason.noCurrentWriter => 'No current writer',
    LogicalWriterHealthReason.multipleWriters => 'Multiple writers unresolved',
    LogicalWriterHealthReason.invariantBlocked => 'Provider invariant blocked',
    LogicalWriterHealthReason.transportUnavailable => 'Transport unavailable',
    LogicalWriterHealthReason.routeUnproven => 'Route not proven',
  };

  String _providerRevisionLabel(LogicalProviderRevisionHealth value) => switch (value) {
    LogicalProviderRevisionHealth.current => 'Current',
    LogicalProviderRevisionHealth.unobserved => 'Not observed',
    LogicalProviderRevisionHealth.stale => 'Stale',
  };

  String _draftLabel(LogicalDraftHealth value) => switch (value) {
    LogicalDraftHealth.none => 'No retained draft',
    LogicalDraftHealth.safe => 'Safe for current authority',
    LogicalDraftHealth.staleRevalidation => 'Stale — revalidation required',
  };

  String _settingsLabel(LogicalConversationSettingsSnapshot settings) {
    if (settings.availability == LogicalSettingsAvailability.unavailable) return 'Unavailable';
    final states = <String>[
      if (settings.isPinned) 'pinned',
      if (settings.isArchived) 'archived',
      if (settings.isMuted) 'muted',
      if (settings.customGroupCount > 0) '${settings.customGroupCount} custom groups',
    ];
    return states.isEmpty ? 'Available' : 'Available (${states.join(', ')})';
  }

  String _indexLabel(LogicalIndexHealth state, int count) =>
      state == LogicalIndexHealth.indexed ? 'Indexed ($count)' : 'Pending';

  Color _stateColor(BuildContext context, LogicalConversationHealthState state) => switch (state) {
    LogicalConversationHealthState.healthy => Colors.green,
    LogicalConversationHealthState.reconciling || LogicalConversationHealthState.indexPending => Colors.amber,
    LogicalConversationHealthState.readSyncPending || LogicalConversationHealthState.writeBlocked => Colors.orange,
    LogicalConversationHealthState.degraded => context.theme.colorScheme.error,
  };
}
