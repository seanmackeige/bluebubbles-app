import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_health.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_settings.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:crypto/crypto.dart';

const logicalConversationApplicationSnapshotSchema = 'LOGICAL_CONVERSATION_APPLICATION_SNAPSHOT_V1';

enum LogicalLatestMessageState { none, observed }

/// Exact latest-message provenance with the raw provider identity discarded.
class LogicalLatestMessageSnapshot {
  const LogicalLatestMessageSnapshot.none()
    : state = LogicalLatestMessageState.none,
      source = null,
      messageFingerprint = null,
      occurredAtEpochMicroseconds = null;

  factory LogicalLatestMessageSnapshot.observed({
    required LogicalConversationId logicalId,
    required PhysicalConversationRef source,
    required String stableMessageId,
    required int occurredAtEpochMicroseconds,
  }) {
    final message = LogicalSearchResult.fromStableMessageId(
      logicalId: logicalId,
      source: source,
      stableMessageId: stableMessageId,
      occurredAtEpochMicroseconds: occurredAtEpochMicroseconds,
    );
    return LogicalLatestMessageSnapshot._(
      state: LogicalLatestMessageState.observed,
      source: message.source,
      messageFingerprint: message.messageFingerprint,
      occurredAtEpochMicroseconds: message.occurredAtEpochMicroseconds,
    );
  }

  const LogicalLatestMessageSnapshot._({
    required this.state,
    required this.source,
    required this.messageFingerprint,
    required this.occurredAtEpochMicroseconds,
  });

  final LogicalLatestMessageState state;
  final PhysicalConversationRef? source;
  final String? messageFingerprint;
  final int? occurredAtEpochMicroseconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state.name,
    if (source != null) 'source_fingerprint': source!.fingerprint,
    if (messageFingerprint != null) 'message_fingerprint': messageFingerprint,
    if (occurredAtEpochMicroseconds != null) 'occurred_at_epoch_microseconds': occurredAtEpochMicroseconds,
  };

  Map<String, Object> get publicSafeFields => <String, Object>{'state': state.name};
}

/// Content-free retained-draft state. Text, subject, paths and attachment names
/// never cross into the application snapshot.
class LogicalDraftApplicationSnapshot {
  const LogicalDraftApplicationSnapshot.none()
    : health = LogicalDraftHealth.none,
      hasText = false,
      attachmentCount = 0,
      hasReply = false,
      contentRevision = 0;

  factory LogicalDraftApplicationSnapshot.fromDraft(LogicalDraft draft, {required LogicalDraftHealth health}) {
    if (health == LogicalDraftHealth.none) {
      throw ArgumentError.value(health, 'health', 'a present draft cannot have none health');
    }
    return LogicalDraftApplicationSnapshot._(
      health: health,
      hasText: draft.text.isNotEmpty || draft.subject.isNotEmpty,
      attachmentCount: draft.attachments.length,
      hasReply: draft.reply != null,
      contentRevision: draft.contentRevision,
    );
  }

  const LogicalDraftApplicationSnapshot._({
    required this.health,
    required this.hasText,
    required this.attachmentCount,
    required this.hasReply,
    required this.contentRevision,
  });

  final LogicalDraftHealth health;
  final bool hasText;
  final int attachmentCount;
  final bool hasReply;
  final int contentRevision;

  Map<String, Object> get publicSafeFields => <String, Object>{
    'health': health.name,
    'has_text': hasText,
    'attachment_count': attachmentCount,
    'has_reply': hasReply,
    'content_revision': contentRevision,
  };
}

enum LogicalSettingsAvailability { available, unavailable }

/// Application presentation settings without custom-group identities or
/// operation-history material.
class LogicalConversationSettingsSnapshot {
  const LogicalConversationSettingsSnapshot.unavailable()
    : availability = LogicalSettingsAvailability.unavailable,
      logicalId = null,
      revision = 0,
      isPinned = false,
      isArchived = false,
      isMuted = false,
      customGroupCount = 0;

  factory LogicalConversationSettingsSnapshot.fromSettings(LogicalConversationSettings settings) {
    return LogicalConversationSettingsSnapshot._(
      availability: LogicalSettingsAvailability.available,
      logicalId: settings.logicalId,
      revision: settings.revision,
      isPinned: settings.isPinned,
      isArchived: settings.isArchived,
      isMuted: settings.isMuted,
      customGroupCount: settings.customGroupIds.length,
    );
  }

  const LogicalConversationSettingsSnapshot._({
    required this.availability,
    required this.logicalId,
    required this.revision,
    required this.isPinned,
    required this.isArchived,
    required this.isMuted,
    required this.customGroupCount,
  });

  final LogicalSettingsAvailability availability;
  final LogicalConversationId? logicalId;
  final int revision;
  final bool isPinned;
  final bool isArchived;
  final bool isMuted;
  final int customGroupCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'availability': availability.name,
    if (logicalId != null) 'logical_id': logicalId!.value,
    'revision': revision,
    'is_pinned': isPinned,
    'is_archived': isArchived,
    'is_muted': isMuted,
    'custom_group_count': customGroupCount,
  };

  Map<String, Object> get publicSafeFields => <String, Object>{
    'availability': availability.name,
    'revision': revision,
    'is_pinned': isPinned,
    'is_archived': isArchived,
    'is_muted': isMuted,
    'custom_group_count': customGroupCount,
  };
}

/// Canonical application-level view of one certified human conversation.
///
/// The core snapshot retains opaque provenance for navigation and indexing;
/// [publicSafeFields] deliberately exports counts and closed states only.
class LogicalConversationApplicationSnapshot {
  LogicalConversationApplicationSnapshot._({
    required this.conversation,
    required this.availableMembers,
    required this.presentationMember,
    required this.latestMessage,
    required this.routeStage,
    required this.generation,
    required this.writer,
    required this.providerRevision,
    required this.readSyncPending,
    required this.notificationReady,
    required this.draft,
    required this.settings,
    required this.health,
  });

  factory LogicalConversationApplicationSnapshot.build({
    required LogicalConversationRegistryEntry registryEntry,
    required Iterable<PhysicalConversationRef> availableMembers,
    required LogicalUnreadLedger unreadLedger,
    LogicalLatestMessageSnapshot latestMessage = const LogicalLatestMessageSnapshot.none(),
    required LogicalRouteRuntimeStage routeStage,
    required LogicalGenerationHealth generation,
    required LogicalWriterHealthReason writer,
    required LogicalProviderRevisionHealth providerRevision,
    required bool readSyncPending,
    required bool notificationReady,
    required LogicalDraftApplicationSnapshot draft,
    required LogicalConversationSettingsSnapshot settings,
    required int relationshipCount,
    required bool relationshipIndexComplete,
    required Iterable<LogicalSearchResult> searchResults,
    required bool searchIndexComplete,
    required Iterable<LogicalMediaItem> mediaItems,
    required bool mediaIndexComplete,
    required int revision,
  }) {
    final availableList = availableMembers.toList(growable: false);
    final availableSet = availableList.toSet();
    if (availableSet.length != availableList.length ||
        availableSet.any((member) => !registryEntry.certifiedMemberRefs.contains(member))) {
      throw StateError('LOGICAL_APPLICATION_SNAPSHOT_AVAILABLE_MEMBER_CONFLICT');
    }
    if (latestMessage.source != null && !registryEntry.certifiedMemberRefs.contains(latestMessage.source)) {
      throw StateError('LOGICAL_APPLICATION_SNAPSHOT_LATEST_MESSAGE_SOURCE_CONFLICT');
    }
    if (settings.logicalId != null && settings.logicalId != registryEntry.logicalId) {
      throw StateError('LOGICAL_APPLICATION_SNAPSHOT_SETTINGS_IDENTITY_CONFLICT');
    }

    final conversation = LogicalConversationSnapshot(
      logicalId: registryEntry.logicalId,
      members: registryEntry.certifiedMemberRefs,
      health: LogicalConversationHealth.derive(
        certifiedSourceCount: registryEntry.members.length,
        availableSourceCount: availableSet.length,
        writeAuthorityReady: writer == LogicalWriterHealthReason.ready,
        partialReadAcknowledgement: readSyncPending,
        integrityConflict: writer == LogicalWriterHealthReason.invariantBlocked,
      ),
      unreadLedger: unreadLedger,
      searchResults: searchResults,
      mediaItems: mediaItems,
      revision: revision,
    );
    final health = LogicalConversationHealthProjection.derive(
      LogicalConversationHealthEvidence(
        snapshot: conversation,
        availableMemberCount: availableSet.length,
        routeStage: routeStage,
        generation: generation,
        writer: writer,
        providerRevision: providerRevision,
        readSyncPending: readSyncPending,
        notificationReady: notificationReady,
        draft: draft.health,
        relationshipCount: relationshipCount,
        relationshipIndexComplete: relationshipIndexComplete,
        searchIndexComplete: searchIndexComplete,
        mediaIndexComplete: mediaIndexComplete,
      ),
    );
    final orderedAvailable = availableSet.toList(growable: false)..sort();
    return LogicalConversationApplicationSnapshot._(
      conversation: conversation,
      availableMembers: List<PhysicalConversationRef>.unmodifiable(orderedAvailable),
      presentationMember: registryEntry.presentationMember.certifiedRef,
      latestMessage: latestMessage,
      routeStage: routeStage,
      generation: generation,
      writer: writer,
      providerRevision: providerRevision,
      readSyncPending: readSyncPending,
      notificationReady: notificationReady,
      draft: draft,
      settings: settings,
      health: health,
    );
  }

  final LogicalConversationSnapshot conversation;
  final List<PhysicalConversationRef> availableMembers;
  final PhysicalConversationRef presentationMember;
  final LogicalLatestMessageSnapshot latestMessage;
  final LogicalRouteRuntimeStage routeStage;
  final LogicalGenerationHealth generation;
  final LogicalWriterHealthReason writer;
  final LogicalProviderRevisionHealth providerRevision;
  final bool readSyncPending;
  final bool notificationReady;
  final LogicalDraftApplicationSnapshot draft;
  final LogicalConversationSettingsSnapshot settings;
  final LogicalConversationHealthProjection health;

  LogicalConversationId get logicalId => conversation.logicalId;
  List<PhysicalConversationRef> get certifiedMembers => conversation.members;
  bool get presentationAvailable => availableMembers.contains(presentationMember);

  String get fingerprint => sha256.convert(utf8.encode(jsonEncode(toJson()))).toString();

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': logicalConversationApplicationSnapshotSchema,
    'conversation': conversation.toJson(),
    'available_members': availableMembers.map((member) => member.fingerprint).toList(growable: false),
    'presentation_member': presentationMember.fingerprint,
    'latest_message': latestMessage.toJson(),
    'route_stage': routeStage.name,
    'generation': generation.name,
    'writer': writer.name,
    'provider_revision': providerRevision.name,
    'read_sync_pending': readSyncPending,
    'notification_ready': notificationReady,
    'draft': draft.publicSafeFields,
    'settings': settings.toJson(),
    'health': health.publicSafeFields,
  };

  Map<String, Object> get publicSafeFields => <String, Object>{
    'schema': logicalConversationApplicationSnapshotSchema,
    'identity_certified': logicalId.isCertified,
    'member_count': certifiedMembers.length,
    'available_member_count': availableMembers.length,
    'presentation_available': presentationAvailable,
    'latest_message': latestMessage.publicSafeFields,
    'route_stage': routeStage.name,
    'generation': generation.name,
    'writer': writer.name,
    'provider_revision': providerRevision.name,
    'unread_source_count': health.unreadSourceCount,
    'source_read_synchronized': health.sourceReadSynchronized,
    'read_sync_pending': readSyncPending,
    'notification_ready': notificationReady,
    'draft': draft.publicSafeFields,
    'settings': settings.publicSafeFields,
    'relationship_count': health.relationshipCount,
    'relationship_index': health.relationshipIndex.name,
    'search_result_count': health.searchResultCount,
    'search_index': health.searchIndex.name,
    'media_item_count': health.mediaItemCount,
    'media_index': health.mediaIndex.name,
    'health': health.state.name,
    'revision': conversation.revision,
  };
}
