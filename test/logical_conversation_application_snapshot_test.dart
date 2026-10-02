import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_application_snapshot.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_health.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry_binding.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_settings.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical conversation application snapshot', () {
    test('covers the complete application projection without content or provider coordinates', () {
      final fixture = _fixture();
      final snapshot = _build(fixture);

      expect(snapshot.logicalId, fixture.entry.logicalId);
      expect(snapshot.certifiedMembers, hasLength(3));
      expect(snapshot.availableMembers, hasLength(3));
      expect(snapshot.presentationAvailable, isTrue);
      expect(snapshot.latestMessage.state, LogicalLatestMessageState.observed);
      expect(snapshot.health.state, LogicalConversationHealthState.healthy);
      expect(snapshot.health.unreadSourceCount, 1);
      expect(snapshot.draft.health, LogicalDraftHealth.safe);
      expect(snapshot.draft.hasText, isTrue);
      expect(snapshot.draft.attachmentCount, 1);
      expect(snapshot.settings.availability, LogicalSettingsAvailability.available);
      expect(snapshot.settings.customGroupCount, 2);
      expect(snapshot.health.searchResultCount, 1);
      expect(snapshot.health.mediaItemCount, 1);

      final publicSafe = jsonEncode(snapshot.publicSafeFields);
      final serialized = jsonEncode(snapshot.toJson());
      for (final forbidden in <String>[
        'human-alpha',
        'source-alpha',
        'source-beta',
        'source-gamma',
        'latest-message-guid',
        'private draft body',
        'private attachment name',
        '/private/attachment/path',
        'rowid',
      ]) {
        expect(publicSafe.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
        expect(serialized.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
      }
    });

    test('missing certified member degrades once and preserves canonical presentation', () {
      final fixture = _fixture();
      final snapshot = _build(fixture, availableMembers: <PhysicalConversationRef>[fixture.refs[0], fixture.refs[2]]);

      expect(snapshot.certifiedMembers, hasLength(3));
      expect(snapshot.availableMembers, hasLength(2));
      expect(snapshot.presentationMember, fixture.refs[1]);
      expect(snapshot.presentationAvailable, isFalse);
      expect(snapshot.health.state, LogicalConversationHealthState.degraded);
      expect(snapshot.publicSafeFields['member_count'], 3);
      expect(snapshot.publicSafeFields['available_member_count'], 2);
    });

    test('member and evidence order cannot change the application fingerprint', () {
      final fixture = _fixture();
      final forward = _build(fixture);
      final reversed = _build(
        fixture,
        availableMembers: fixture.refs.reversed,
        searchResults: fixture.searchResults.reversed,
        mediaItems: fixture.mediaItems.reversed,
      );

      expect(reversed.fingerprint, forward.fingerprint);
      expect(reversed.publicSafeFields, forward.publicSafeFields);
    });

    test('foreign, duplicate, and identity-mismatched evidence fails closed', () {
      final fixture = _fixture();
      final foreign = PhysicalConversationRef.fromStablePhysicalGuid('foreign-source');

      expect(
        () => _build(fixture, availableMembers: <PhysicalConversationRef>[...fixture.refs, foreign]),
        throwsA(isA<StateError>()),
      );
      expect(
        () => _build(fixture, availableMembers: <PhysicalConversationRef>[fixture.refs[0], fixture.refs[0]]),
        throwsA(isA<StateError>()),
      );
      expect(
        () => _build(
          fixture,
          latestMessage: LogicalLatestMessageSnapshot.observed(
            logicalId: fixture.entry.logicalId,
            source: foreign,
            stableMessageId: 'foreign-message',
            occurredAtEpochMicroseconds: 1,
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => _build(
          fixture,
          settings: LogicalConversationSettingsSnapshot.fromSettings(
            LogicalConversationSettings(logicalId: LogicalConversationId.certified('other-human')),
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => _build(
          fixture,
          unreadLedger: LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[fixture.refs.first]),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('closed health priority remains deterministic at the application boundary', () {
      final fixture = _fixture();

      expect(
        _build(fixture, routeStage: LogicalRouteRuntimeStage.checking).health.state,
        LogicalConversationHealthState.reconciling,
      );
      expect(_build(fixture, readSyncPending: true).health.state, LogicalConversationHealthState.readSyncPending);
      expect(
        _build(fixture, writer: LogicalWriterHealthReason.noCurrentWriter).health.state,
        LogicalConversationHealthState.writeBlocked,
      );
      expect(_build(fixture, searchIndexComplete: false).health.state, LogicalConversationHealthState.indexPending);
      expect(_build(fixture, notificationReady: false).health.state, LogicalConversationHealthState.degraded);
    });
  });
}

({
  LogicalConversationRegistryEntry entry,
  List<PhysicalConversationRef> refs,
  LogicalUnreadLedger unreadLedger,
  LogicalLatestMessageSnapshot latestMessage,
  LogicalDraftApplicationSnapshot draft,
  LogicalConversationSettingsSnapshot settings,
  List<LogicalSearchResult> searchResults,
  List<LogicalMediaItem> mediaItems,
})
_fixture() {
  final logicalId = LogicalConversationId.certified('human-alpha');
  final runtimeRefs = <PhysicalConversationRef>[
    PhysicalConversationRef.fromStablePhysicalGuid('source-alpha'),
    PhysicalConversationRef.fromStablePhysicalGuid('source-beta'),
    PhysicalConversationRef.fromStablePhysicalGuid('source-gamma'),
  ];
  final members = <LogicalConversationRegistryMember>[
    _member(runtimeRefs[0], 'source-alpha', 11),
    _member(runtimeRefs[1], 'source-beta', 12, presentation: true),
    _member(runtimeRefs[2], 'source-gamma', 13),
  ];
  final entry = LogicalConversationRegistryEntry(logicalId: logicalId, members: members);
  final refs = members.map((member) => member.certifiedRef).toList(growable: false);
  final unreadLedger = LogicalUnreadLedger(certifiedSources: refs)
    ..observe(LogicalUnreadObservation(source: refs[0], revision: 1, hasUnread: true, eventWatermark: 10))
    ..observe(LogicalUnreadObservation(source: refs[1], revision: 1, hasUnread: false, eventWatermark: 20))
    ..observe(LogicalUnreadObservation(source: refs[2], revision: 1, hasUnread: false, eventWatermark: 30));
  final draft = LogicalDraftApplicationSnapshot.fromDraft(
    LogicalDraft(
      logicalId: 'human-alpha',
      text: 'private draft body',
      subject: '',
      attachments: const <LogicalAttachmentIntent>[
        LogicalAttachmentIntent(
          intentId: 'private-attachment-id',
          name: 'private attachment name',
          size: 10,
          isRestorable: true,
          path: '/private/attachment/path',
        ),
      ],
      contentRevision: 4,
      createdAtEpochMilliseconds: 1,
      updatedAtEpochMilliseconds: 2,
    ),
    health: LogicalDraftHealth.safe,
  );
  final settings = LogicalConversationSettingsSnapshot.fromSettings(
    LogicalConversationSettings(
      logicalId: logicalId,
      revision: 3,
      isPinned: true,
      pinIndex: 1,
      isMuted: true,
      customGroupIds: const <int>{7, 8},
    ),
  );
  final searchResults = <LogicalSearchResult>[
    LogicalSearchResult.fromStableMessageId(
      logicalId: logicalId,
      source: refs[0],
      stableMessageId: 'search-message-guid',
      occurredAtEpochMicroseconds: 100,
    ),
  ];
  final mediaItems = <LogicalMediaItem>[
    LogicalMediaItem.fromStableIds(
      logicalId: logicalId,
      source: refs[2],
      stableMessageId: 'media-message-guid',
      stableMediaId: 'media-guid',
      kind: LogicalMediaKind.photo,
      availability: LogicalMediaAvailability.available,
      occurredAtEpochMicroseconds: 200,
    ),
  ];
  return (
    entry: entry,
    refs: refs,
    unreadLedger: unreadLedger,
    latestMessage: LogicalLatestMessageSnapshot.observed(
      logicalId: logicalId,
      source: refs[1],
      stableMessageId: 'latest-message-guid',
      occurredAtEpochMicroseconds: 300,
    ),
    draft: draft,
    settings: settings,
    searchResults: searchResults,
    mediaItems: mediaItems,
  );
}

LogicalConversationRegistryMember _member(
  PhysicalConversationRef ref,
  String providerGuid,
  int rowId, {
  bool presentation = false,
}) {
  return LogicalConversationRegistryMember(
    physicalRef: ref,
    sourceChatRowId: rowId,
    providerGuidFingerprint: LogicalConversationRegistryBinding.providerGuidFingerprint(providerGuid),
    isPresentation: presentation,
  );
}

LogicalConversationApplicationSnapshot _build(
  ({
    LogicalConversationRegistryEntry entry,
    List<PhysicalConversationRef> refs,
    LogicalUnreadLedger unreadLedger,
    LogicalLatestMessageSnapshot latestMessage,
    LogicalDraftApplicationSnapshot draft,
    LogicalConversationSettingsSnapshot settings,
    List<LogicalSearchResult> searchResults,
    List<LogicalMediaItem> mediaItems,
  })
  fixture, {
  Iterable<PhysicalConversationRef>? availableMembers,
  LogicalUnreadLedger? unreadLedger,
  LogicalLatestMessageSnapshot? latestMessage,
  LogicalRouteRuntimeStage routeStage = LogicalRouteRuntimeStage.qualified,
  LogicalWriterHealthReason writer = LogicalWriterHealthReason.ready,
  bool readSyncPending = false,
  bool notificationReady = true,
  LogicalDraftApplicationSnapshot? draft,
  LogicalConversationSettingsSnapshot? settings,
  Iterable<LogicalSearchResult>? searchResults,
  bool searchIndexComplete = true,
  Iterable<LogicalMediaItem>? mediaItems,
}) {
  return LogicalConversationApplicationSnapshot.build(
    registryEntry: fixture.entry,
    availableMembers: availableMembers ?? fixture.refs,
    unreadLedger: unreadLedger ?? fixture.unreadLedger,
    latestMessage: latestMessage ?? fixture.latestMessage,
    routeStage: routeStage,
    generation: routeStage == LogicalRouteRuntimeStage.checking
        ? LogicalGenerationHealth.reconciling
        : LogicalGenerationHealth.current,
    writer: writer,
    providerRevision: LogicalProviderRevisionHealth.current,
    readSyncPending: readSyncPending,
    notificationReady: notificationReady,
    draft: draft ?? fixture.draft,
    settings: settings ?? fixture.settings,
    relationshipCount: 4,
    relationshipIndexComplete: true,
    searchResults: searchResults ?? fixture.searchResults,
    searchIndexComplete: searchIndexComplete,
    mediaItems: mediaItems ?? fixture.mediaItems,
    mediaIndexComplete: true,
    revision: 9,
  );
}
