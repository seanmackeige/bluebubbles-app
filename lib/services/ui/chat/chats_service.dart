import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:bluebubbles/app/layouts/chat_creator/chat_creator.dart';
import 'package:bluebubbles/app/layouts/chat_creator/new_chat_creator.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/filters/chat_list_filters.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/interfaces/chat_interface.dart';
import 'package:bluebubbles/services/backend/interfaces/sync_interface.dart';
import 'package:bluebubbles/services/backend/notifications/desktop_notification.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:bluebubbles/models/models.dart' show HandleLookupKey, MessageSaveResult;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart' hide Response;
import 'package:mime_type/mime_type.dart';
import 'package:path/path.dart' as path_util;
import 'package:universal_io/io.dart';
import 'package:bluebubbles/database/database.dart';
import 'package:get_it/get_it.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';

// ignore: non_constant_identifier_names
ChatsService get ChatsSvc => GetIt.I<ChatsService>();

class _LogicalRouteMessageSnapshot {
  const _LogicalRouteMessageSnapshot({required this.messages, required this.complete});

  final List<Map<String, dynamic>> messages;
  final bool complete;
}

class _LogicalRouteChatScopeSnapshot {
  const _LogicalRouteChatScopeSnapshot({required this.chats, required this.complete, required this.fingerprint});

  final List<Map<String, dynamic>> chats;
  final bool complete;
  final String fingerprint;
}

class _LogicalChatGenerationProperties {
  const _LogicalChatGenerationProperties({
    required this.complete,
    required this.lastKnownHybridState,
    required this.shouldForceToSms,
    required this.lastSeenMessageGuid,
    required this.groupPhotoGuid,
  });

  final bool complete;
  final bool? lastKnownHybridState;
  final bool? shouldForceToSms;
  final String? lastSeenMessageGuid;
  final String? groupPhotoGuid;
}

class _LogicalSourceHydrationCursor {
  LogicalProjectionCacheIdentity? identity;
  int nextOffset = 0;
  int? providerTotal;
  String? headGuid;
  int? headRowId;
  String? tailGuid;
  int? tailRowId;
  int eventWatermark = 0;
  bool exhausted = false;

  void reset({int? toEventWatermark}) {
    nextOffset = 0;
    providerTotal = null;
    headGuid = null;
    headRowId = null;
    tailGuid = null;
    tailRowId = null;
    if (toEventWatermark != null) eventWatermark = toEventWatermark;
    exhausted = false;
  }
}

class ChatsService {
  static const batchSize = 100;
  int currentCount = 0;
  StreamSubscription? countSub;
  bool headless = false;

  final RxBool hasChats = false.obs;
  Completer<void> loadedAllChats = Completer();
  final RxBool loadedFirstChatBatch = false.obs;

  /// Global unread count across all chats
  final RxInt unreadCount = 0.obs;

  /// Current read-only qualification of the certified logical execution
  /// route. This is presentation state only; every queued mutation is resolved
  /// again before the existing send pipeline can perform optimistic writes.
  final Rx<LogicalRouteRuntimeStatus> logicalRouteRuntimeStatus = const LogicalRouteRuntimeStatus.unchecked().obs;
  LogicalRouteEvidence? _logicalRouteEvidence;
  DateTime? _logicalRouteEvidenceAt;
  final Map<int, LogicalTransportReadinessEvidence> _logicalTransportReadinessBySourceRow =
      <int, LogicalTransportReadinessEvidence>{};
  Completer<void>? _logicalEvidenceMutex;
  final LogicalEvidenceObservationEpochTracker _logicalEvidenceObservationEpochTracker =
      LogicalEvidenceObservationEpochTracker();
  final LogicalAuthorityRevisionTracker _logicalAuthorityRevisionTracker = LogicalAuthorityRevisionTracker();
  Completer<void>? _logicalDraftMutex;
  Completer<void>? _logicalDraftAttachmentStagingMutex;
  final Map<String, int> _logicalDraftGenerations = <String, int>{};
  Completer<void>? _logicalHydrationMutex;
  final Map<String, _LogicalSourceHydrationCursor> _logicalHydrationCursors = <String, _LogicalSourceHydrationCursor>{};
  final Map<String, int> _logicalSourceEventWatermarks = <String, int>{};

  LogicalAuthorityRevision? get currentLogicalAuthorityRevision => _logicalAuthorityRevisionTracker.current;

  LogicalTransportReadinessEvidence? logicalTransportReadinessForSourceRow(int sourceRowId) =>
      _logicalTransportReadinessBySourceRow[sourceRowId];

  bool isLogicalEvidenceObservationCurrent(int epoch) => _logicalEvidenceObservationEpochTracker.isCurrent(epoch);

  Future<T> _withLogicalDraftLock<T>(Future<T> Function() operation) async {
    while (_logicalDraftMutex != null) {
      await _logicalDraftMutex!.future;
    }
    final mutex = Completer<void>();
    _logicalDraftMutex = mutex;
    try {
      return await operation();
    } finally {
      if (identical(_logicalDraftMutex, mutex)) _logicalDraftMutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }

  /// Map of chat states for granular reactivity
  /// Key is the chat GUID, value is the ChatState
  /// The map itself doesn't need to be Rx because the underlying ChatState fields are
  final Map<String, ChatState> chatStates = {};

  ChatState? _activeChat;
  ChatState? get activeChat => _activeChat;
  set activeChat(ChatState? value) {
    _activeChat = value;
    final guid = value?.chat.guid;
    if (activeChatGuid.value != guid) activeChatGuid.value = guid;
  }

  /// Reactive guid of the active chat. Tiles observe this for highlighting instead
  /// of a ChatState instance — it survives chatStates being cleared/rebuilt (reset,
  /// reload) and never diverges from a permanent tile controller's captured state.
  final RxnString activeChatGuid = RxnString();

  /// Sorted list of chats maintained for efficient access
  /// Updated on add/update using binary search insertion O(log n + n)
  /// instead of sorting entire list O(n log n) on every access
  final List<Chat> _sortedChats = [];

  /// Reactive counter that increments when chat list order changes
  /// Used to trigger UI rebuilds when chats are repositioned
  final RxInt chatListVersion = 0.obs;

  /// Currently selected conversation-list filter dimensions. Persisted to
  /// [Settings] only via an explicit "Save as Default" action in the filter
  /// sheet — see [saveChatListFiltersAsDefault].
  final Rx<ChatListFilters> chatListFilters = const ChatListFilters().obs;

  /// Timer for debouncing chatListVersion updates to prevent rapid UI rebuilds
  Timer? _listVersionUpdateTimer;

  /// Listeners for redacted mode settings to update all ChatStates
  StreamSubscription? _redactedModeListener;
  StreamSubscription? _hideContactInfoListener;
  StreamSubscription? _generateFakeAvatarsListener;
  StreamSubscription? _hideAttachmentsListener;

  /// Rebuilds the chat list whenever [CustomGroupsSvc.groups] changes (e.g.
  /// a chat added to/removed from a group via the conversation peek view),
  /// since the `customGroupIds` filter branch in [getFilteredChats] reads
  /// membership from there.
  StreamSubscription? _customGroupsListener;

  // ========== Helper Getters (replacing direct chats access) ==========

  /// Get all chats as a list (non-reactive), sorted by pin index and latest message date
  /// Returns the pre-sorted list for O(1) access instead of O(n log n) sorting
  List<Chat> get allChats {
    return _projectLogicalChatList(_sortedChats);
  }

  /// Check if chats list is empty
  bool get isEmpty {
    return chatStates.isEmpty;
  }

  /// Get number of chats
  int get length {
    return allChats.length;
  }

  List<ChatState> get presentationChatStates =>
      allChats.map((chat) => chatStates[chat.guid]).whereType<ChatState>().toList();

  List<Chat> _logicalCandidateChats() {
    final byGuid = <String, Chat>{
      for (final state in chatStates.values)
        if (LogicalConversationViewPolicy.isApprovedSourceRowId(state.chat.originalROWID)) state.chat.guid: state.chat,
    };
    if (LogicalConversationViewPolicy.resolve(byGuid.values.map((chat) => chat.originalROWID)) != null) {
      return byGuid.values.toList();
    }
    if (!kIsWeb) {
      final query = Database.chats
          .query(Chat_.originalROWID.oneOf(LogicalConversationViewPolicy.comcastNodeUpdates.sourceChatRowIds.toList()))
          .build();
      for (final chat in query.find()) {
        byGuid.putIfAbsent(chat.guid, () => chat);
      }
      query.close();
    }
    return byGuid.values.toList();
  }

  LogicalConversationReadCertificate? get _logicalDefinition =>
      LogicalConversationViewPolicy.resolve(_logicalCandidateChats().map((chat) => chat.originalROWID));

  List<Chat> _logicalSourceChats(LogicalConversationReadCertificate definition) {
    final sources = _logicalCandidateChats()
        .where((chat) => definition.containsSourceRowId(chat.originalROWID))
        .map((chat) => findChatByGuid(chat.guid) ?? chat)
        .toList();
    sources.sort((a, b) => a.originalROWID!.compareTo(b.originalROWID!));
    return sources;
  }

  /// True for either protected source ROWID even while the second source is
  /// absent. Write guards intentionally fail closed before projection activates.
  bool isApprovedLogicalSource(Chat chat) => LogicalConversationViewPolicy.isApprovedSourceRowId(chat.originalROWID);

  bool isLogicalConversation(Chat chat) {
    final definition = _logicalDefinition;
    return definition != null && definition.containsSourceRowId(chat.originalROWID);
  }

  String? logicalConversationIdFor(Chat chat) {
    final definition = _logicalDefinition;
    return definition != null && definition.containsSourceRowId(chat.originalROWID) ? definition.id : null;
  }

  List<Chat> logicalSourceChatsFor(Chat chat) {
    final definition = _logicalDefinition;
    if (definition == null || !definition.containsSourceRowId(chat.originalROWID)) {
      return <Chat>[chat];
    }
    return _logicalSourceChats(definition);
  }

  /// Advances reconstructible pagination metadata whenever a source event is
  /// observed outside the hydration fetch itself. Any existing source cursor
  /// must re-establish its provider boundary before it can fetch another page.
  void noteLogicalSourceEvent(String physicalChatGuid) {
    final definition = _logicalDefinition;
    final source =
        findChatByGuid(physicalChatGuid) ??
        (definition == null
            ? null
            : _logicalSourceChats(definition).firstWhereOrNull((candidate) => candidate.guid == physicalChatGuid));
    if (source == null || !isApprovedLogicalSource(source)) return;
    _logicalSourceEventWatermarks.update(physicalChatGuid, (value) => value + 1, ifAbsent: () => 1);
    invalidateLogicalAuthority('LOGICAL_SOURCE_EVENT_OBSERVED');
  }

  Chat presentationChatFor(Chat chat) {
    final definition = _logicalDefinition;
    if (definition == null || !definition.containsSourceRowId(chat.originalROWID)) {
      return chat;
    }
    return _logicalSourceChats(
      definition,
    ).firstWhere((source) => source.originalROWID == definition.presentationSourceChatRowId);
  }

  /// Reads every message needed by route qualification without allowing an
  /// arbitrary first-page limit to pick a physical writer. Concurrent source
  /// evolution, duplicate pages, or histories beyond the bound fail closed.
  Future<_LogicalRouteMessageSnapshot> _collectLogicalRouteMessageSnapshot(String guid) async {
    const pageSize = 1000;
    const maxMessages = 5000;
    final messages = <Map<String, dynamic>>[];
    int? expectedTotal;
    String? firstGuid;
    int? firstRowId;

    for (var offset = 0; offset < maxMessages; offset += pageSize) {
      final response = await HttpSvc.chat.getMessages(guid, offset: offset, limit: pageSize);
      final rawPage = response.data['data'];
      final rawMetadata = response.data['metadata'];
      if (rawPage is! List || rawMetadata is! Map) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
      final page = rawPage.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList();
      if (page.length != rawPage.length) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
      final metadata = rawMetadata.cast<String, dynamic>();
      final total = (metadata['total'] as num?)?.toInt();
      final count = (metadata['count'] as num?)?.toInt();
      if (total == null || total < 0 || total > maxMessages || count != page.length) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
      if (expectedTotal == null) {
        expectedTotal = total;
        if (page.isNotEmpty) {
          firstGuid = page.first['guid']?.toString();
          firstRowId = (page.first['originalROWID'] as num?)?.toInt();
        }
      } else if (expectedTotal != total) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
      messages.addAll(page);
      if (messages.length >= total) break;
      if (page.length != pageSize) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
    }

    if (expectedTotal == null || messages.length != expectedTotal) {
      return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
    }
    final rows = <int>{};
    final guids = <String>{};
    for (final message in messages) {
      final rowId = (message['originalROWID'] as num?)?.toInt();
      final messageGuid = message['guid']?.toString();
      if (rowId == null || rowId <= 0 || messageGuid == null || messageGuid.isEmpty) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
      if (!rows.add(rowId) || !guids.add(messageGuid)) {
        return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
      }
    }

    final verification = await HttpSvc.chat.getMessages(guid, offset: 0, limit: 1);
    final verificationPage = verification.data['data'];
    final verificationMetadata = verification.data['metadata'];
    if (verificationPage is! List || verificationMetadata is! Map) {
      return _LogicalRouteMessageSnapshot(messages: messages, complete: false);
    }
    final verificationTotal = (verificationMetadata['total'] as num?)?.toInt();
    final verificationFirst = verificationPage.whereType<Map>().firstOrNull;
    final verificationGuid = verificationFirst?['guid']?.toString();
    final verificationRowId = (verificationFirst?['originalROWID'] as num?)?.toInt();
    final stable =
        verificationTotal == expectedTotal &&
        (expectedTotal == 0 || (verificationGuid == firstGuid && verificationRowId == firstRowId));
    return _LogicalRouteMessageSnapshot(messages: messages, complete: stable);
  }

  Future<_LogicalRouteChatScopeSnapshot> _collectLogicalRouteChatScope() async {
    const pageSize = 1000;
    const maxChats = 10000;
    final chats = <Map<String, dynamic>>[];
    int? expectedTotal;

    for (var offset = 0; offset < maxChats; offset += pageSize) {
      final response = await HttpSvc.chat.query(withQuery: const ['participants'], offset: offset, limit: pageSize);
      final rawPage = response.data['data'];
      final rawMetadata = response.data['metadata'];
      if (rawPage is! List || rawMetadata is! Map) {
        return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
      }
      final page = rawPage.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList();
      if (page.length != rawPage.length) {
        return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
      }
      final metadata = rawMetadata.cast<String, dynamic>();
      final total = (metadata['total'] as num?)?.toInt();
      final count = (metadata['count'] as num?)?.toInt();
      if (total == null || total < 0 || total > maxChats || count != page.length) {
        return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
      }
      expectedTotal ??= total;
      if (expectedTotal != total) {
        return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
      }
      chats.addAll(page);
      if (chats.length >= total) break;
      if (page.length != pageSize) {
        return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
      }
    }

    if (expectedTotal == null || chats.length != expectedTotal) {
      return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
    }
    final rows = <int>{};
    final guids = <String>{};
    for (final chat in chats) {
      final rowId = (chat['originalROWID'] as num?)?.toInt();
      final guid = chat['guid']?.toString();
      if (rowId == null || rowId <= 0 || guid == null || guid.isEmpty || !rows.add(rowId) || !guids.add(guid)) {
        return const _LogicalRouteChatScopeSnapshot(chats: [], complete: false, fingerprint: '');
      }
    }
    return _LogicalRouteChatScopeSnapshot(
      chats: chats,
      complete: true,
      fingerprint: _logicalRouteChatScopeFingerprint(chats),
    );
  }

  Future<LogicalRouteEvidence> _collectLogicalRouteEvidence(Chat chat) async {
    final definition = _logicalDefinition;
    final sources = logicalSourceChatsFor(chat)
      ..sort((a, b) => (a.originalROWID ?? -1).compareTo(b.originalROWID ?? -1));
    if (definition == null || sources.length != definition.sourceChatRowIds.length) {
      return LogicalRouteEvidence(
        logicalId: definition?.id ?? '',
        certificateId: null,
        certifiedSourceChatGuids: const {},
        backendComputerId: '',
        detectedIMessage: false,
        privateApiConnected: false,
        helperConnected: false,
        accountSnapshotBeforeSha256: '',
        accountSnapshotAfterSha256: '',
        activeSelfAlias: const LogicalAddressEvidence(address: ''),
        vettedSelfAliases: const [],
        executionGenerationCertificate: null,
        candidateScopeSnapshotComplete: false,
        unadmittedPotentialSourceChatGuids: const {},
        candidates: const [],
      );
    }

    final accountBeforeResponse = await HttpSvc.icloud.getAccountInfo();
    final candidateScopeBefore = await _collectLogicalRouteChatScope();
    final requests = <Future<dynamic>>[HttpSvc.server.info(force: true)];
    final messageSnapshots = <Future<_LogicalRouteMessageSnapshot>>[];
    for (final source in sources) {
      requests.add(HttpSvc.chat.fetchOne(source.guid, withQuery: 'participants'));
      messageSnapshots.add(_collectLogicalRouteMessageSnapshot(source.guid));
    }
    final responses = await Future.wait(requests);
    final snapshots = await Future.wait(messageSnapshots);
    final chatVerificationResponses = await Future.wait(
      sources.map((source) => HttpSvc.chat.fetchOne(source.guid, withQuery: 'participants')),
    );
    final candidateScopeAfter = await _collectLogicalRouteChatScope();
    final accountAfterResponse = await HttpSvc.icloud.getAccountInfo();
    final serverAfterResponse = await HttpSvc.server.info(force: true);
    final serverData = Map<String, dynamic>.from((responses.first.data['data'] as Map).cast<String, dynamic>());
    final serverAfterData = Map<String, dynamic>.from(
      (serverAfterResponse.data['data'] as Map).cast<String, dynamic>(),
    );
    final serverBefore = _logicalServerProjection(serverData);
    final serverAfter = _logicalServerProjection(serverAfterData);
    final serverSnapshotStable = serverBefore.fingerprint == serverAfter.fingerprint;
    final accountBefore = _logicalAccountProjection(accountBeforeResponse.data['data']);
    final accountAfter = _logicalAccountProjection(accountAfterResponse.data['data']);

    final candidates = <LogicalRouteCandidateEvidence>[];
    for (var index = 0; index < sources.length; index++) {
      final chatData = Map<String, dynamic>.from((responses[1 + index].data['data'] as Map).cast<String, dynamic>());
      final verificationChatData = Map<String, dynamic>.from(
        (chatVerificationResponses[index].data['data'] as Map).cast<String, dynamic>(),
      );
      final snapshot = snapshots[index];
      final rawMessages = snapshot.messages;
      final successfulOutbounds = <LogicalSuccessfulOutboundEvidence>[];
      final messages = <LogicalRouteMessageEvidence>[];
      for (final message in rawMessages) {
        final rowId = (message['originalROWID'] as num?)?.toInt();
        final guid = message['guid']?.toString();
        final createdAt = (message['dateCreated'] as num?)?.toInt();
        final error = (message['error'] as num?)?.toInt();
        final itemType = (message['itemType'] as num?)?.toInt();
        final isFromMe = message['isFromMe'];
        final associatedMessageGuid = message['associatedMessageGuid']?.toString();
        if (rowId == null ||
            rowId <= 0 ||
            guid == null ||
            guid.isEmpty ||
            createdAt == null ||
            createdAt <= 0 ||
            error == null ||
            itemType == null ||
            isFromMe is! bool) {
          continue;
        }
        messages.add(
          LogicalRouteMessageEvidence(
            messageGuid: guid,
            messageRowId: rowId,
            createdAtEpoch: createdAt,
            isFromMe: isFromMe,
            error: error,
            itemType: itemType,
            associatedMessageGuid: associatedMessageGuid,
          ),
        );
        if (message['isFromMe'] == true &&
            error == 0 &&
            itemType == 0 &&
            (associatedMessageGuid == null || associatedMessageGuid.isEmpty)) {
          successfulOutbounds.add(
            LogicalSuccessfulOutboundEvidence(
              messageGuid: guid,
              messageRowId: rowId,
              createdAtEpoch: createdAt,
              terminalAcknowledgement: message['isSent'] == true && message['isFinished'] == true,
            ),
          );
        }
      }
      final participants = <LogicalAddressEvidence>[];
      final rawParticipants = chatData['participants'];
      if (rawParticipants is List) {
        for (final raw in rawParticipants.whereType<Map>()) {
          final address = raw['address']?.toString();
          if (address != null && address.isNotEmpty) {
            participants.add(LogicalAddressEvidence(address: address, country: raw['country']?.toString()));
          }
        }
      }
      final properties = _logicalChatGenerationProperties(chatData);
      final verificationProperties = _logicalChatGenerationProperties(verificationChatData);
      candidates.add(
        LogicalRouteCandidateEvidence(
          sourceChatRowId: (chatData['originalROWID'] as num?)?.toInt() ?? -1,
          sourceChatGuid: chatData['guid']?.toString() ?? '',
          sourceService: _logicalChatService(chatData['guid']),
          chatIdentifier: chatData['chatIdentifier']?.toString() ?? '',
          style: (chatData['style'] as num?)?.toInt() ?? -1,
          lastAddressedHandle: LogicalAddressEvidence(address: chatData['lastAddressedHandle']?.toString() ?? ''),
          participants: participants,
          chatSnapshotComplete:
              properties.complete &&
              verificationProperties.complete &&
              _logicalChatRouteFingerprint(chatData) == _logicalChatRouteFingerprint(verificationChatData),
          messageSnapshotComplete: snapshot.complete && messages.length == rawMessages.length,
          lastKnownHybridState: properties.lastKnownHybridState,
          shouldForceToSms: properties.shouldForceToSms,
          lastSeenMessageGuid: properties.lastSeenMessageGuid,
          groupPhotoGuid: properties.groupPhotoGuid,
          messages: messages,
          successfulOutbounds: successfulOutbounds,
        ),
      );
    }

    final candidateScopeSnapshotComplete =
        candidateScopeBefore.complete &&
        candidateScopeAfter.complete &&
        candidateScopeBefore.fingerprint == candidateScopeAfter.fingerprint;
    final unadmittedPotentialSources = candidateScopeSnapshotComplete
        ? _logicalUnadmittedPotentialSources(
            candidateScopeAfter.chats,
            candidates,
            accountBefore.vettedAliases.map((alias) => LogicalAddressEvidence(address: alias)).toList(),
          )
        : const <int, String>{};

    return LogicalRouteEvidence(
      logicalId: definition.id,
      certificateId: '$logicalConversationOutboundRouteSchema:${definition.id}',
      certifiedSourceChatGuids: {
        for (final source in sources)
          if (source.originalROWID != null) source.originalROWID!: source.guid,
      },
      backendComputerId: serverSnapshotStable ? serverBefore.computerId : '',
      detectedIMessage: serverSnapshotStable && serverBefore.detectedIMessage,
      privateApiConnected: serverSnapshotStable && serverBefore.privateApiConnected,
      helperConnected: serverSnapshotStable && serverBefore.helperConnected,
      accountSnapshotBeforeSha256: accountBefore.fingerprint,
      accountSnapshotAfterSha256: accountAfter.fingerprint,
      activeSelfAlias: LogicalAddressEvidence(address: accountBefore.activeAlias),
      vettedSelfAliases: accountBefore.vettedAliases.map((alias) => LogicalAddressEvidence(address: alias)).toList(),
      executionGenerationCertificate: LogicalConversationOutboundRoutePolicy.comcastNodeUpdatesGeneration,
      candidateScopeSnapshotComplete: candidateScopeSnapshotComplete,
      unadmittedPotentialSourceChatGuids: unadmittedPotentialSources,
      candidates: candidates,
    );
  }

  String _logicalChatService(dynamic rawGuid) {
    if (rawGuid is! String || rawGuid.isEmpty) return '';
    final separator = rawGuid.indexOf(';');
    return separator <= 0 ? '' : rawGuid.substring(0, separator);
  }

  _LogicalChatGenerationProperties _logicalChatGenerationProperties(Map<String, dynamic> chatData) {
    final rawProperties = chatData['properties'];
    if (rawProperties is! List || rawProperties.length != 1 || rawProperties.single is! Map) {
      return const _LogicalChatGenerationProperties(
        complete: false,
        lastKnownHybridState: null,
        shouldForceToSms: null,
        lastSeenMessageGuid: null,
        groupPhotoGuid: null,
      );
    }
    final properties = (rawProperties.single as Map).cast<String, dynamic>();
    final rawHybrid = properties['lastKnownHybridState'];
    final rawForceSms = properties['shouldForceToSMS'];
    final rawLastSeen = properties['lastSeenMessageGuid'];
    final rawGroupPhoto = properties['groupPhotoGuid'];
    final valid =
        (rawHybrid == null || rawHybrid is bool) &&
        rawForceSms is bool &&
        rawLastSeen is String &&
        rawLastSeen.isNotEmpty &&
        (rawGroupPhoto == null || (rawGroupPhoto is String && rawGroupPhoto.isNotEmpty));
    return _LogicalChatGenerationProperties(
      complete: valid,
      lastKnownHybridState: rawHybrid is bool ? rawHybrid : null,
      shouldForceToSms: rawForceSms is bool ? rawForceSms : null,
      lastSeenMessageGuid: rawLastSeen is String && rawLastSeen.isNotEmpty ? rawLastSeen : null,
      groupPhotoGuid: rawGroupPhoto is String && rawGroupPhoto.isNotEmpty ? rawGroupPhoto : null,
    );
  }

  String _logicalChatRouteFingerprint(Map<String, dynamic> chatData) {
    final properties = _logicalChatGenerationProperties(chatData);
    final participants = <Map<String, String?>>[];
    final rawParticipants = chatData['participants'];
    if (rawParticipants is List) {
      for (final raw in rawParticipants.whereType<Map>()) {
        participants.add({
          'address': raw['address']?.toString(),
          'country': raw['country']?.toString(),
          'service': raw['service']?.toString(),
        });
      }
    }
    participants.sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
    final projection = {
      'originalROWID': (chatData['originalROWID'] as num?)?.toInt(),
      'guid': chatData['guid']?.toString(),
      'chatIdentifier': chatData['chatIdentifier']?.toString(),
      'style': (chatData['style'] as num?)?.toInt(),
      'lastAddressedHandle': chatData['lastAddressedHandle']?.toString(),
      'participants': participants,
      'propertiesComplete': properties.complete,
      'lastKnownHybridState': properties.lastKnownHybridState,
      'shouldForceToSms': properties.shouldForceToSms,
      'lastSeenMessageGuid': properties.lastSeenMessageGuid,
      'groupPhotoGuid': properties.groupPhotoGuid,
    };
    return sha256.convert(utf8.encode(jsonEncode(projection))).toString();
  }

  String _logicalRouteChatScopeFingerprint(List<Map<String, dynamic>> chats) {
    final projection = chats.map((chat) {
      final properties = _logicalChatGenerationProperties(chat);
      final participants = <Map<String, String?>>[];
      final rawParticipants = chat['participants'];
      if (rawParticipants is List) {
        for (final raw in rawParticipants.whereType<Map>()) {
          participants.add({
            'address': raw['address']?.toString(),
            'country': raw['country']?.toString(),
            'service': raw['service']?.toString(),
          });
        }
      }
      participants.sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
      return {
        'originalROWID': (chat['originalROWID'] as num?)?.toInt(),
        'guid': chat['guid']?.toString(),
        'style': (chat['style'] as num?)?.toInt(),
        'groupId': chat['groupId']?.toString(),
        'groupPhotoGuid': properties.groupPhotoGuid,
        'participants': participants,
      };
    }).toList()..sort((left, right) => (left['originalROWID'] as int).compareTo(right['originalROWID'] as int));
    return sha256.convert(utf8.encode(jsonEncode(projection))).toString();
  }

  Map<int, String> _logicalUnadmittedPotentialSources(
    List<Map<String, dynamic>> scope,
    List<LogicalRouteCandidateEvidence> certified,
    List<LogicalAddressEvidence> vettedAliases,
  ) {
    final certifiedRows = certified.map((candidate) => candidate.sourceChatRowId).toSet();
    final vetted = vettedAliases
        .map(LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress)
        .whereType<String>()
        .toSet();
    final acceptedExternal = _logicalExternalParticipants(certified.first.participants, vetted);
    if (acceptedExternal == null) return const {};

    final certifiedScope = scope.where((chat) => certifiedRows.contains((chat['originalROWID'] as num?)?.toInt()));
    final certifiedGroupIds = certifiedScope
        .map((chat) => chat['groupId']?.toString())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet();
    final certifiedGroupPhotoGuids = certified
        .map((candidate) => candidate.groupPhotoGuid)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet();

    final potential = <int, String>{};
    for (final chat in scope) {
      final rowId = (chat['originalROWID'] as num?)?.toInt();
      final guid = chat['guid']?.toString();
      if (rowId == null || guid == null || certifiedRows.contains(rowId) || (chat['style'] as num?)?.toInt() != 43) {
        continue;
      }
      final rawParticipants = chat['participants'];
      final participants = <LogicalAddressEvidence>[];
      if (rawParticipants is List) {
        for (final raw in rawParticipants.whereType<Map>()) {
          final address = raw['address']?.toString();
          if (address != null && address.isNotEmpty) {
            participants.add(LogicalAddressEvidence(address: address, country: raw['country']?.toString()));
          }
        }
      }
      final external = _logicalExternalParticipants(participants, vetted);
      final groupId = chat['groupId']?.toString();
      final groupPhotoGuid = _logicalChatGenerationProperties(chat).groupPhotoGuid;
      final sameExternal = external != null && _logicalSameSet(external, acceptedExternal);
      final sameGroupId = groupId != null && groupId.isNotEmpty && certifiedGroupIds.contains(groupId);
      final sameGroupPhoto =
          groupPhotoGuid != null && groupPhotoGuid.isNotEmpty && certifiedGroupPhotoGuids.contains(groupPhotoGuid);
      if (sameExternal || sameGroupId || sameGroupPhoto) {
        potential[rowId] = guid;
      }
    }
    return potential;
  }

  Set<String>? _logicalExternalParticipants(List<LogicalAddressEvidence> participants, Set<String> vettedAliases) {
    final normalized = <String>{};
    for (final participant in participants) {
      final value = LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(participant);
      if (value == null || !normalized.add(value)) return null;
    }
    return normalized.difference(vettedAliases);
  }

  bool _logicalSameSet<T>(Set<T> left, Set<T> right) =>
      left.length == right.length && left.containsAll(right) && right.containsAll(left);

  ({String computerId, bool detectedIMessage, bool privateApiConnected, bool helperConnected, String fingerprint})
  _logicalServerProjection(Map<String, dynamic> server) {
    final computerId = server['computer_id']?.toString() ?? '';
    final detectedIMessage = switch (server['detected_imessage']) {
      final String value => value.trim().isNotEmpty,
      final bool value => value,
      _ => false,
    };
    final privateApiConnected = server['private_api'] == true;
    final helperConnected = server['helper_connected'] == true;
    final projection = <String, dynamic>{
      'computerId': computerId,
      'detectedIMessage': detectedIMessage,
      'privateApiConnected': privateApiConnected,
      'helperConnected': helperConnected,
    };
    return (
      computerId: computerId,
      detectedIMessage: detectedIMessage,
      privateApiConnected: privateApiConnected,
      helperConnected: helperConnected,
      fingerprint: sha256.convert(utf8.encode(jsonEncode(projection))).toString(),
    );
  }

  ({String fingerprint, String activeAlias, List<String> vettedAliases}) _logicalAccountProjection(dynamic raw) {
    if (raw is! Map) {
      return (fingerprint: '', activeAlias: '', vettedAliases: const []);
    }
    final account = raw.cast<String, dynamic>();
    List<Map<String, dynamic>> projectAliases(dynamic value) {
      if (value is! List) return const [];
      final projected = <Map<String, dynamic>>[];
      for (final item in value.whereType<Map>()) {
        final alias = item['Alias'];
        final status = item['Status'];
        final visible = item['IsUserVisible'];
        if (alias is! String || alias.isEmpty || status is! num || visible is! bool) {
          return const [];
        }
        projected.add({'alias': alias, 'status': status.toInt(), 'visible': visible});
      }
      projected.sort((a, b) {
        final byAlias = (a['alias'] as String).compareTo(b['alias'] as String);
        if (byAlias != 0) return byAlias;
        final byStatus = (a['status'] as int).compareTo(b['status'] as int);
        return byStatus != 0 ? byStatus : (a['visible'] == b['visible'] ? 0 : (a['visible'] == true ? 1 : -1));
      });
      return projected;
    }

    final aliases = projectAliases(account['aliases']);
    final vetted = projectAliases(account['vetted_aliases']);
    final activeAlias = account['active_alias'];
    final appleId = account['apple_id'];
    if (aliases.isEmpty ||
        vetted.isEmpty ||
        activeAlias is! String ||
        activeAlias.isEmpty ||
        appleId is! String ||
        appleId.isEmpty) {
      return (fingerprint: '', activeAlias: '', vettedAliases: const []);
    }
    final projection = {'aliases': aliases, 'vetted_aliases': vetted, 'active_alias': activeAlias, 'apple_id': appleId};
    return (
      fingerprint: sha256.convert(utf8.encode(jsonEncode(projection))).toString(),
      activeAlias: activeAlias,
      vettedAliases: vetted.map((item) => item['alias'] as String).toList(),
    );
  }

  Future<({LogicalRouteEvidence evidence, int observationEpoch})> _currentLogicalRouteEvidence(
    Chat chat, {
    bool force = false,
  }) async {
    while (_logicalEvidenceMutex != null) {
      await _logicalEvidenceMutex!.future;
    }
    final mutex = Completer<void>();
    _logicalEvidenceMutex = mutex;
    try {
      final now = DateTime.now();
      if (!force &&
          _logicalRouteEvidence != null &&
          _logicalRouteEvidenceAt != null &&
          now.difference(_logicalRouteEvidenceAt!) < const Duration(minutes: 1)) {
        return (
          evidence: _logicalRouteEvidence!,
          observationEpoch: _logicalEvidenceObservationEpochTracker.completedEpoch,
        );
      }
      // A forced execution-boundary read begins only after every older
      // observer has finished. Older provider evidence can therefore never
      // complete late and overwrite a newer authority revision.
      final observationEpoch = _logicalEvidenceObservationEpochTracker.begin();
      final evidence = await _collectLogicalRouteEvidence(chat);
      _logicalRouteEvidence = evidence;
      _logicalRouteEvidenceAt = DateTime.now();
      _logicalEvidenceObservationEpochTracker.complete(observationEpoch);
      return (evidence: evidence, observationEpoch: observationEpoch);
    } finally {
      if (identical(_logicalEvidenceMutex, mutex)) _logicalEvidenceMutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }

  /// Resolves a batch from one complete evidence snapshot. Every decision and
  /// its revision therefore describe the same point-in-time provider truth.
  Future<
    ({
      List<LogicalRouteDecision> decisions,
      List<LogicalTransportReadinessEvidence> transportReadiness,
      LogicalAuthorityRevision? revision,
      int? observationEpoch,
    })
  >
  resolveLogicalMutationBatch(Chat chat, List<LogicalMutationRequest> requests, {bool force = false}) async {
    final observedAt = DateTime.now().millisecondsSinceEpoch;
    LogicalTransportReadinessEvidence unavailableEvidence(String reason) => LogicalTransportReadinessEvidence(
      service: 'UNKNOWN',
      state: LogicalTransportReadinessState.unknown,
      strength: LogicalTransportEvidenceStrength.unavailable,
      reason: reason,
      observedAtEpochMilliseconds: observedAt,
    );
    if (!isLogicalConversation(chat)) {
      if (isApprovedLogicalSource(chat)) {
        logicalRouteRuntimeStatus.value = const LogicalRouteRuntimeStatus(
          stage: LogicalRouteRuntimeStage.routeNotProven,
          reason: 'MISSING_OR_AMBIGUOUS_LOGICAL_SOURCE_BINDING',
        );
      }
      return (
        decisions: [
          for (final _ in requests) const LogicalRouteDecision.notProven('NOT_A_CERTIFIED_LOGICAL_CONVERSATION'),
        ],
        transportReadiness: [for (final _ in requests) unavailableEvidence('TRANSPORT_ROUTE_NOT_QUALIFIED')],
        revision: null,
        observationEpoch: null,
      );
    }
    if (requests.any((request) => request.mutationClass == LogicalMutationClass.newMessage)) {
      logicalRouteRuntimeStatus.value = const LogicalRouteRuntimeStatus.checking();
    }
    try {
      final observation = await _currentLogicalRouteEvidence(chat, force: force);
      final evidence = observation.evidence;
      final definition = _logicalDefinition;
      if (definition == null) {
        return (
          decisions: [
            for (final _ in requests)
              const LogicalRouteDecision.notProven('MISSING_OR_AMBIGUOUS_LOGICAL_SOURCE_BINDING'),
          ],
          transportReadiness: [for (final _ in requests) unavailableEvidence('TRANSPORT_ROUTE_NOT_QUALIFIED')],
          revision: null,
          observationEpoch: observation.observationEpoch,
        );
      }
      final authorityDecision = LogicalConversationOutboundRoutePolicy.resolve(
        evidence,
        const LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage),
      );
      final authorityMaterial = <String, dynamic>{
        'evidence': evidence.authorityRevision,
        'routeReason': authorityDecision.reason,
        'routeTargets': authorityDecision.physicalTargetRowIds,
      };
      final revision = _logicalAuthorityRevisionTracker.observe(
        certificateRevision: definition.revision,
        authorityRevision: sha256.convert(utf8.encode(jsonEncode(authorityMaterial))).toString(),
      );
      final decisions = <LogicalRouteDecision>[
        for (final request in requests) LogicalConversationOutboundRoutePolicy.resolve(evidence, request),
      ];
      final transportReadiness = <LogicalTransportReadinessEvidence>[
        for (final decision in decisions)
          LogicalTransportReadinessPolicy.resolve(evidence, decision, observedAtEpochMilliseconds: observedAt),
      ];
      _logicalTransportReadinessBySourceRow.clear();
      for (var index = 0; index < decisions.length; index++) {
        final decision = decisions[index];
        if (decision.isSingleTarget) {
          _logicalTransportReadinessBySourceRow[decision.physicalTargetRowIds.single] = transportReadiness[index];
        }
      }
      for (var index = 0; index < requests.length; index++) {
        final request = requests[index];
        final decision = decisions[index];
        Logger.info(
          'Logical route decision: mutation=${request.mutationClass.name}, '
          'reason=${decision.reason}, targetCount=${decision.physicalTargetRowIds.length}, '
          'targetRowId=${decision.isSingleTarget ? decision.physicalTargetRowIds.single : 'NONE'}, '
          'authorityEpoch=${revision.epoch}',
          tag: 'LogicalConversationRoute',
        );
      }
      final newMessageDecision = <int>[
        for (var index = 0; index < requests.length; index++)
          if (requests[index].mutationClass == LogicalMutationClass.newMessage) index,
      ].firstOrNull;
      if (newMessageDecision != null) {
        final decision = decisions[newMessageDecision];
        logicalRouteRuntimeStatus.value = LogicalRouteRuntimeStatus(
          stage: decision.isSingleTarget ? LogicalRouteRuntimeStage.qualified : LogicalRouteRuntimeStage.routeNotProven,
          reason: decision.reason,
          targetRowId: decision.isSingleTarget ? decision.physicalTargetRowIds.single : null,
          certificateRevision: revision.certificateRevision,
          authorityRevision: revision.authorityRevision,
          authorityEpoch: revision.epoch,
          service: transportReadiness[newMessageDecision].service,
          transportReadiness: transportReadiness[newMessageDecision].effectiveStateAt(observedAt),
          transportReason: transportReadiness[newMessageDecision].reason,
          sendDisposition: transportReadiness[newMessageDecision].sendDispositionAt(observedAt),
        );
      }
      return (
        decisions: decisions,
        transportReadiness: transportReadiness,
        revision: revision,
        observationEpoch: observation.observationEpoch,
      );
    } catch (_) {
      Logger.warn('Logical route evidence unavailable; mutation remains fail closed', tag: 'LogicalConversationRoute');
      _logicalAuthorityRevisionTracker.invalidate('CURRENT_ROUTE_EVIDENCE_UNAVAILABLE');
      if (requests.any((request) => request.mutationClass == LogicalMutationClass.newMessage)) {
        logicalRouteRuntimeStatus.value = const LogicalRouteRuntimeStatus(
          stage: LogicalRouteRuntimeStage.routeNotProven,
          reason: 'CURRENT_ROUTE_EVIDENCE_UNAVAILABLE',
        );
      }
      return (
        decisions: [
          for (final _ in requests) const LogicalRouteDecision.notProven('CURRENT_ROUTE_EVIDENCE_UNAVAILABLE'),
        ],
        transportReadiness: [for (final _ in requests) unavailableEvidence('TRANSPORT_PROVIDER_EVIDENCE_UNAVAILABLE')],
        revision: null,
        observationEpoch: null,
      );
    }
  }

  /// Resolves one mutation class from current server/source evidence. No
  /// mutation occurs here; this method only selects physical targets.
  Future<LogicalRouteDecision> resolveLogicalMutation(
    Chat chat,
    LogicalMutationRequest request, {
    bool force = false,
  }) async {
    final result = await resolveLogicalMutationBatch(chat, <LogicalMutationRequest>[request], force: force);
    return result.decisions.single;
  }

  void invalidateLogicalAuthority(String reason) {
    _logicalRouteEvidence = null;
    _logicalRouteEvidenceAt = null;
    _logicalTransportReadinessBySourceRow.clear();
    _logicalEvidenceObservationEpochTracker.invalidate();
    final revision = _logicalAuthorityRevisionTracker.invalidate(reason);
    logicalRouteRuntimeStatus.value = LogicalRouteRuntimeStatus(
      stage: LogicalRouteRuntimeStage.unchecked,
      reason: reason,
      certificateRevision: revision.certificateRevision,
      authorityRevision: revision.authorityRevision,
      authorityEpoch: revision.epoch,
    );
  }

  LogicalDraft? loadLogicalDraft(Chat chat) {
    final definition = _logicalDefinition;
    if (definition == null || !definition.containsSourceRowId(chat.originalROWID)) return null;
    final raw = PrefsSvc.messaging.loadLogicalDraftJson(definition.id);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = LogicalDraft.fromJson(decoded.cast<String, dynamic>());
      return draft.logicalId == definition.id ? draft : null;
    } catch (error, stack) {
      Logger.warn('Logical draft is unreadable and remains untouched', error: error, trace: stack, tag: 'LogicalDraft');
      return null;
    }
  }

  int logicalDraftGenerationFor(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
    return logicalId == null ? 0 : (_logicalDraftGenerations[logicalId] ?? 0);
  }

  Future<LogicalDraft?> saveLogicalDraft(
    Chat chat, {
    required String text,
    required String subject,
    required List<LogicalAttachmentIntent> attachments,
    required LogicalReplyIntent? reply,
    String? effectId,
    int? expectedDraftGeneration,
  }) {
    return _withLogicalDraftLock(() async {
      final definition = _logicalDefinition;
      if (definition == null || !definition.containsSourceRowId(chat.originalROWID)) {
        throw StateError('NOT_A_CERTIFIED_LOGICAL_CONVERSATION');
      }
      if (expectedDraftGeneration != null &&
          (_logicalDraftGenerations[definition.id] ?? 0) != expectedDraftGeneration) {
        return null;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing =
          loadLogicalDraft(chat) ??
          LogicalDraft.create(
            logicalId: definition.id,
            nowEpochMilliseconds: now,
            observedRevision: currentLogicalAuthorityRevision,
          );
      final updated = existing.mergeUserIntent(
        text: text,
        subject: subject,
        attachments: attachments,
        reply: reply,
        effectId: effectId,
        updatedAtEpochMilliseconds: now,
      );
      await PrefsSvc.messaging.saveLogicalDraftJson(definition.id, jsonEncode(updated.toJson()));
      return updated;
    });
  }

  /// Freezes a route-neutral logical send intent before any physical route is
  /// selected. This is shared by the main composer, voice messages, and
  /// pre-navigation ChatCreator sends so every logical entrypoint has the same
  /// draft custody and attachment staging semantics.
  Future<LogicalDraft?> saveLogicalSendIntent(
    Chat chat, {
    required String text,
    required String subject,
    required List<PlatformFile> attachments,
    required LogicalReplyIntent? reply,
    String? effectId,
    int? expectedDraftGeneration,
  }) async {
    if (!isLogicalConversation(chat)) return null;
    await _stageLogicalDraftAttachments(chat, attachments);
    final currentAttachments = <LogicalAttachmentIntent>[
      for (var index = 0; index < attachments.length; index++)
        LogicalAttachmentIntent(
          intentId: sha256
              .convert(
                utf8.encode(
                  '${attachments[index].path ?? 'EPHEMERAL'}\u0000'
                  '${attachments[index].name}\u0000'
                  '${attachments[index].size}\u0000$index',
                ),
              )
              .toString(),
          name: attachments[index].name,
          size: attachments[index].size,
          isRestorable: attachments[index].path != null,
          path: attachments[index].path,
          mimeType: mime(attachments[index].path) ?? mime(attachments[index].name),
        ),
    ];
    final existing = loadLogicalDraft(chat);
    final unavailable =
        existing?.attachments.where(
          (prior) =>
              !prior.isRestorable &&
              !currentAttachments.any((current) => current.name == prior.name && current.size == prior.size),
        ) ??
        const <LogicalAttachmentIntent>[];
    return saveLogicalDraft(
      chat,
      text: text,
      subject: subject,
      attachments: <LogicalAttachmentIntent>[...unavailable, ...currentAttachments],
      reply: reply,
      effectId: effectId,
      expectedDraftGeneration: expectedDraftGeneration,
    );
  }

  Future<void> _stageLogicalDraftAttachments(Chat chat, List<PlatformFile> attachments) async {
    if (kIsWeb || attachments.isEmpty) return;
    while (_logicalDraftAttachmentStagingMutex != null) {
      await _logicalDraftAttachmentStagingMutex!.future;
    }
    final staging = Completer<void>();
    _logicalDraftAttachmentStagingMutex = staging;
    try {
      final logicalId = logicalConversationIdFor(chat);
      if (logicalId == null) throw StateError('NOT_A_CERTIFIED_LOGICAL_CONVERSATION');
      final logicalPathId = sha256.convert(utf8.encode(logicalId)).toString().substring(0, 24);
      final directory = Directory(path_util.join(FilesystemSvc.appTempPath, 'logical-drafts', logicalPathId));
      await directory.create(recursive: true);
      for (final selected in attachments) {
        final currentPath = selected.path;
        if (currentPath != null && currentPath.startsWith('${directory.path}${Platform.pathSeparator}')) continue;
        final List<int> bytes;
        if (currentPath != null) {
          final source = File(currentPath);
          if (!await source.exists()) throw StateError('LOGICAL_ATTACHMENT_SOURCE_UNAVAILABLE');
          bytes = await source.readAsBytes();
        } else if (selected.bytes != null) {
          bytes = selected.bytes!;
        } else {
          throw StateError('LOGICAL_ATTACHMENT_SOURCE_UNAVAILABLE');
        }
        final digest = sha256.convert(bytes).toString();
        final safeName = selected.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final target = File(path_util.join(directory.path, '$digest-$safeName'));
        if (!await target.exists()) await target.writeAsBytes(bytes, flush: true);
        selected.path = target.path;
      }
    } finally {
      if (identical(_logicalDraftAttachmentStagingMutex, staging)) {
        _logicalDraftAttachmentStagingMutex = null;
      }
      if (!staging.isCompleted) staging.complete();
    }
  }

  Future<void> persistRearmedLogicalDraft(LogicalDraft draft) {
    return _withLogicalDraftLock(() async {
      final currentRaw = PrefsSvc.messaging.loadLogicalDraftJson(draft.logicalId);
      if (currentRaw != null) {
        try {
          final current = LogicalDraft.fromJson((jsonDecode(currentRaw) as Map).cast<String, dynamic>());
          if (current.contentRevision != draft.contentRevision ||
              current.contentFingerprint != draft.contentFingerprint) {
            return;
          }
        } catch (_) {
          return;
        }
      }
      await PrefsSvc.messaging.saveLogicalDraftJson(draft.logicalId, jsonEncode(draft.toJson()));
    });
  }

  Future<bool> clearLogicalDraftIfCurrent(LogicalDraft admittedDraft) {
    return _withLogicalDraftLock(() async {
      final currentRaw = PrefsSvc.messaging.loadLogicalDraftJson(admittedDraft.logicalId);
      if (currentRaw == null) return true;
      try {
        final current = LogicalDraft.fromJson((jsonDecode(currentRaw) as Map).cast<String, dynamic>());
        if (current.contentRevision != admittedDraft.contentRevision ||
            current.contentFingerprint != admittedDraft.contentFingerprint ||
            current.observedCertificateRevision != admittedDraft.observedCertificateRevision ||
            current.observedAuthorityRevision != admittedDraft.observedAuthorityRevision ||
            current.observedAuthorityEpoch != admittedDraft.observedAuthorityEpoch) {
          return false;
        }
      } catch (_) {
        return false;
      }
      _logicalDraftGenerations.update(admittedDraft.logicalId, (value) => value + 1, ifAbsent: () => 1);
      await PrefsSvc.messaging.clearLogicalDraft(admittedDraft.logicalId);
      return true;
    });
  }

  Future<LogicalRouteDecision> prepareLogicalRoute(Chat chat, {bool force = false}) => resolveLogicalMutation(
    chat,
    const LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage),
    force: force,
  );

  /// Marks only currently unread certified source chats as read. A logical
  /// read operation may intentionally have more than one physical target.
  Future<LogicalRouteDecision> markLogicalConversationRead(Chat chat) async {
    final sources = logicalSourceChatsFor(chat);
    final unreadRows = sources
        .where((source) => source.hasUnreadMessage == true)
        .map((source) => source.originalROWID)
        .whereType<int>()
        .toSet();
    final decision = await resolveLogicalMutation(
      chat,
      LogicalMutationRequest(mutationClass: LogicalMutationClass.markRead, unreadSourceChatRowIds: unreadRows),
      force: true,
    );
    if (!decision.isQualified) return decision;
    for (final rowId in decision.physicalTargetRowIds) {
      final source = sources.firstWhere((candidate) => candidate.originalROWID == rowId);
      await HttpSvc.chat.markRead(source.guid);
      await source.toggleHasUnreadAsync(false, privateMark: false);
      getChatState(source.guid)?.updateHasUnreadInternal(false);
    }
    _syncLogicalPresentationState();
    return decision;
  }

  String presentationGuidFor(String guid) {
    final definition = _logicalDefinition;
    final chat =
        findChatByGuid(guid) ??
        (definition == null
            ? null
            : _logicalSourceChats(definition).firstWhereOrNull((candidate) => candidate.guid == guid));
    return chat == null ? guid : presentationChatFor(chat).guid;
  }

  List<Chat> _projectLogicalChatList(Iterable<Chat> rawChats) {
    final projected = LogicalConversationViewPolicy.projectConversationList(rawChats, (chat) => chat.originalROWID);
    projected.sort(_sortCompare);
    return projected;
  }

  void _syncLogicalPresentationState() {
    final definition = _logicalDefinition;
    if (definition == null) return;
    final sources = _logicalSourceChats(definition);
    final presentation = sources.firstWhere((chat) => chat.originalROWID == definition.presentationSourceChatRowId);
    final presentationState = chatStates[presentation.guid];
    if (presentationState == null) return;

    final latestMessages = sources.map((source) => source.dbLatestMessage.target).whereType<Message>().toList()
      ..sort(Message.sort);
    if (latestMessages.isNotEmpty && presentationState.latestMessage.value?.guid != latestMessages.first.guid) {
      presentationState.updateLatestMessageInternal(latestMessages.first);
    }
    final unread = LogicalConversationViewPolicy.logicalUnread(
      sources.map((source) => source.hasUnreadMessage ?? false),
    );
    presentationState.updateHasUnreadInternal(unread);
  }

  void _refreshLogicalPresentation({bool immediate = true}) {
    _syncLogicalPresentationState();
    final definition = _logicalDefinition;
    if (definition == null) return;
    final presentation = _logicalSourceChats(
      definition,
    ).firstWhere((chat) => chat.originalROWID == definition.presentationSourceChatRowId);
    _repositionChat(presentation, immediate: immediate);
  }

  /// Find chat by GUID
  Chat? findChatByGuid(String guid) {
    return chatStates[guid]?.chat;
  }

  /// Find chat by chat identifier
  Chat? findChatByChatIdentifier(String chatIdentifier) {
    return chatStates.values.map((state) => state.chat).firstWhereOrNull((c) => c.chatIdentifier == chatIdentifier);
  }

  /// Get chat at specific index (from sorted list)
  Chat? getChatAtIndex(int index) {
    final sortedChats = getSortedChats();
    if (index < 0 || index >= sortedChats.length) return null;
    return sortedChats[index];
  }

  /// Get filtered chats (archived, unknown senders, pinned)
  List<Chat> getFilteredChats({
    bool? showArchived,
    bool? showUnknown,
    bool? pinnedOnly,
    bool? excludePinned,
    ChatListFilters? filters,
  }) {
    var chats = allChats;

    // Apply archived filter
    if (showArchived != null) {
      if (showArchived) {
        chats = chats.where((e) => e.isArchived ?? false).toList();
      } else {
        chats = chats.where((e) => !(e.isArchived ?? false)).toList();
      }
    }

    // Apply unknown senders filter
    if (showUnknown != null && SettingsSvc.settings.filterUnknownSenders.value) {
      if (showUnknown) {
        chats = chats.where((e) => !e.isGroup && e.handles.firstOrNull?.contactsV2.isEmpty != false).toList();
      } else {
        chats = chats
            .where((e) => e.isGroup || (!e.isGroup && e.handles.firstOrNull?.contactsV2.isNotEmpty == true))
            .toList();
      }
    }

    // Apply conversation-list filter dimensions (chip selections) — these combine with AND semantics.
    if (filters != null) {
      if (filters.readFilter == ChatReadFilter.unread) {
        // Read from ChatState rather than the Chat model directly — markAllAsRead()
        // updates ChatState.hasUnreadMessage instantly but writes the underlying
        // Chat.hasUnreadMessage field asynchronously via a background DB/HTTP call,
        // so the model field can briefly lag behind the reactive state.
        chats = chats
            .where((e) => getChatState(e.guid)?.hasUnreadMessage.value ?? (e.hasUnreadMessage ?? false))
            .toList();
      }

      // The legacy "Filter Unknown Senders" setting already siphons unknown-sender
      // chats into their own separate list (see the showUnknown block above and
      // Chat.shouldMuteNotification) — when it's on, it takes precedence over this
      // chip so the two mechanisms can't fight and produce a confusing empty list.
      if (!SettingsSvc.settings.filterUnknownSenders.value) {
        if (filters.senderFilter == ChatSenderFilter.known) {
          chats = chats
              .where((e) => e.isGroup || (!e.isGroup && e.handles.firstOrNull?.contactsV2.isNotEmpty == true))
              .toList();
        } else if (filters.senderFilter == ChatSenderFilter.unknown) {
          chats = chats.where((e) => !e.isGroup && e.handles.firstOrNull?.contactsV2.isEmpty != false).toList();
        }
      }

      if (filters.typeFilter == ChatTypeFilter.group) {
        chats = chats.where((e) => e.isGroup).toList();
      } else if (filters.typeFilter == ChatTypeFilter.direct) {
        chats = chats.where((e) => !e.isGroup).toList();
      }

      if (filters.muteFilter == ChatMuteFilter.muted) {
        chats = chats.where((e) => e.muteType != null).toList();
      } else if (filters.muteFilter == ChatMuteFilter.unmuted) {
        chats = chats.where((e) => e.muteType == null).toList();
      }

      if (filters.serviceFilter == ChatServiceFilter.iMessage) {
        chats = chats.where((e) => e.isIMessage).toList();
      } else if (filters.serviceFilter == ChatServiceFilter.other) {
        chats = chats.where((e) => !e.isIMessage).toList();
      }

      if (filters.customGroupIds.isNotEmpty) {
        // Sourced from CustomGroupsSvc.groups (refreshed on every
        // 'custom-groups-updated' event) rather than `e.customGroups` —
        // that backlink ToMany is lazily loaded and cached per Chat instance
        // (e.g. by CustomGroupFilterChipRow's unread-count badges), so it
        // goes stale as soon as a chat is added to/removed from a group and
        // never picks up the change without this.
        final matchingGuids = CustomGroupsSvc.groups
            .where((g) => filters.customGroupIds.contains(g.id))
            .expand((g) => g.chats)
            .map((c) => c.guid)
            .toSet();
        chats = chats.where((e) => matchingGuids.contains(e.guid)).toList();
      }
    }

    // Apply pinned filter
    if (pinnedOnly == true) {
      chats = chats.where((e) => e.isPinned ?? false).toList();
    } else if (excludePinned == true) {
      chats = chats.where((e) => !(e.isPinned ?? false)).toList();
    }

    return chats;
  }

  /// Get only group chats
  List<Chat> get groupChats {
    return allChats.where((c) => c.isGroup).toList();
  }

  /// Get pinned chats
  List<Chat> get pinnedChats {
    return getSortedChats().where((c) => (c.pinIndex ?? -1) >= 0).toList()
      ..sort((a, b) => (a.pinIndex ?? 0).compareTo(b.pinIndex ?? 0));
  }

  /// Search chats by title
  List<Chat> searchChats(String query) {
    return allChats
        .where((element) => element.getTitle().toLowerCase().replaceAll(" ", "").contains(query.toLowerCase()))
        .toList();
  }

  /// Get next chat in sorted list (for keyboard navigation)
  Chat? getNextChat(String currentGuid) {
    final sortedChats = getSortedChats();
    final index = sortedChats.indexWhere((e) => e.guid == currentGuid);
    if (index > -1 && index < sortedChats.length - 1) {
      return sortedChats[index + 1];
    }
    return null;
  }

  /// Get previous chat in sorted list (for keyboard navigation)
  Chat? getPreviousChat(String currentGuid) {
    final sortedChats = getSortedChats();
    final index = sortedChats.indexWhere((e) => e.guid == currentGuid);
    if (index > 0 && index < sortedChats.length) {
      return sortedChats[index - 1];
    }
    return null;
  }

  final List<Handle> webCachedHandles = [];

  void initDbWatchers() {
    if (headless) return;
    if (!kIsWeb) {
      // watch for new chats
      final countQuery = (Database.chats.query(
        Chat_.dateDeleted.isNull(),
      )..order(Chat_.id, flags: Order.descending)).watch(triggerImmediately: true);
      countSub = countQuery.listen((event) async {
        if (!SettingsSvc.settings.finishedSetup.value) return;
        final newCount = event.count();
        if (newCount > currentCount && currentCount != 0) {
          final chat = event.findFirst()!;
          if (chat.dbOnlyLatestMessageDate == null || chat.dbOnlyLatestMessageDate!.millisecondsSinceEpoch == 0) {
            // wait for the chat.addMessage to go through
            await Future.delayed(const Duration(milliseconds: 500));
          }
          await addChat(chat, immediate: true);
        }
        currentCount = newCount;
      });
    } else {
      countSub = WebListeners.newChat.listen((chat) async {
        if (!SettingsSvc.settings.finishedSetup.value) return;
        await addChat(chat, immediate: true);
      });
    }
  }

  Future<void> init({bool force = false, bool headless = false}) async {
    this.headless = headless;
    if ((!force && !SettingsSvc.settings.finishedSetup.value) || headless) {
      return;
    }
    Logger.info("Fetching chats...", tag: "ChatBloc");

    reset();

    // Preload the saved default filter selection (if any) — independent of
    // chat count, so set this up unconditionally.
    _loadDefaultChatListFilters();

    // Existing ObjectBox rows predate source-ROWID persistence. Refresh only
    // the two reviewed source rows from the normal read API so an upgrade can
    // activate deterministically without clearing the cache.
    await _backfillApprovedLogicalSourceRows();

    // Get current count from database or server
    currentCount =
        getChatCount() ??
        (await HttpSvc.chat.getCount().catchError((err) {
          Logger.info("Error when fetching chat count!", tag: "ChatBloc");
          return Response(requestOptions: RequestOptions(path: ''));
        })).data['data']['total'] ??
        0;

    loadedAllChats = Completer();
    if (currentCount != 0) {
      hasChats.value = true;
    } else {
      loadedFirstChatBatch.value = true;
      initDbWatchers();
      return;
    }

    // Clear existing chats to avoid duplicates on re-init
    if (chatStates.isNotEmpty) {
      chatStates.clear();
      _sortedChats.clear();
    }

    final batches = (currentCount / batchSize).ceil();
    for (int i = 0; i < batches; i++) {
      final chatBatch = await Chat.getChatsAsync(limit: batchSize, offset: i * batchSize);
      if (kIsWeb) {
        webCachedHandles.addAll(chatBatch.map((e) => e.handles).flattened.toList());
        final ids = webCachedHandles.map((e) => e.address).toSet();
        webCachedHandles.retainWhere((element) => ids.remove(element.address));
      }

      // Insert each chat at the correct position using binary search
      // This maintains proper ordering including pinIndex which DB queries cannot handle
      for (Chat c in chatBatch) {
        // Create ChatState and add to map
        final state = chatStates[c.guid] = ChatState(c);
        _setupChatStateListeners(state);

        if (activeChatGuid.value == c.guid) {
          _activeChat = state;
          state.updateActiveAndAliveInternal(true);
        }

        // Add to sorted list
        _insertChatSorted(c);
      }
      loadedFirstChatBatch.value = true;
      // Increment chatListVersion after every batch so the UI rebuilds for each batch,
      // not just the first. loadedFirstChatBatch only fires once (false→true), so
      // subsequent batches would otherwise silently mutate _sortedChats with no Obx signal.
      _scheduleListVersionUpdate();
    }

    loadedAllChats.complete();
    Logger.info("Finished fetching chats (${chatStates.length}).", tag: "ChatBloc");

    _refreshLogicalPresentation(immediate: false);

    // Calculate initial unread count now that all chat states are populated.
    // The listener only fires on changes, so we need an explicit call here to
    // seed the badge with the correct value before any message is received.
    _recalculateUnreadCount();

    if (kIsDesktop) {
      unawaited(
        DesktopNotifications.cancelStale(
          keepGroups: presentationChatStates
              .where((state) => state.hasUnreadMessage.value)
              .map((state) => state.chat.guid)
              .toList(),
        ),
      );
    }

    // Initialize watchers AFTER loading all chats to avoid duplicates
    initDbWatchers();

    // Set up global listeners for redacted mode settings
    _setupRedactedModeListeners();

    // Rebuild the chat list whenever custom-group membership changes. Listens
    // to CustomGroupsSvc.groups directly (rather than the raw
    // 'custom-groups-updated' event) so it only fires once CustomGroupsSvc has
    // already re-fetched — no redundant DB query here — and debounces via
    // _scheduleListVersionUpdate so a burst of changes (e.g. restoring many
    // groups from a backup, each of which fires its own event) collapses into
    // a single rebuild instead of one per group.
    _customGroupsListener?.cancel();
    _customGroupsListener = CustomGroupsSvc.groups.listen((_) => _scheduleListVersionUpdate());

    if (kIsDesktop && Platform.isWindows) {
      /* ----- IMESSAGE:// HANDLER ----- */
      final _appLinks = AppLinks();
      _appLinks.stringLinkStream.listen((String string) async {
        if (!string.startsWith("imessage://")) return;
        final uri = Uri.tryParse(
          string
              .replaceFirst("imessage://", "imessage:")
              .replaceFirst("&body=", "?body=")
              .replaceFirst(RegExp(r'/$'), ''),
        );
        if (uri == null) return;

        final address = uri.path;
        final handle = Handle.findOne(addressAndService: HandleLookupKey(address, "iMessage"));
        NavigationSvc.closeSettings(Get.context!);
        await NavigationSvc.pushAndRemoveUntil(
          Get.context!,
          NewChatCreator(
            initialSelected: [SelectedContact(displayName: handle?.displayName ?? address, address: address)],
            initialText: uri.queryParameters['body'],
          ),
          (route) => route.isFirst,
        );
      });
    }
  }

  /// Get ChatState for a specific chat GUID
  ChatState? getChatState(String guid) {
    return chatStates[guid];
  }

  /// Returns the [ChatState] for [chat], creating a bare one if it doesn't exist yet.
  ///
  /// Used by [ConversationView] to obtain a state instance before the chat list
  /// has fully loaded (e.g. opened via deep-link or chat creator). The returned
  /// state is cached in [chatStates] so subsequent lookups return the same instance.
  ChatState getOrCreateChatState(Chat chat) {
    return chatStates.putIfAbsent(chat.guid, () => ChatState(chat));
  }

  /// Set up listeners on a ChatState to track unread count changes
  void _setupChatStateListeners(ChatState chatState) {
    // Listen to hasUnreadMessage changes to update global unread count
    chatState.hasUnreadMessage.listen((hasUnread) {
      _recalculateUnreadCount();
    });
  }

  /// The filter selection currently saved as default (see
  /// [saveChatListFiltersAsDefault]). Falls back to [ChatListFilters]'s
  /// built-in defaults if nothing has been explicitly saved.
  ChatListFilters get savedDefaultChatListFilters {
    final saved = SettingsSvc.settings.savedChatFilters.value;
    return saved.isEmpty ? const ChatListFilters() : ChatListFilters.fromSettingsMap(saved);
  }

  /// Loads the saved default filter selection (if one was explicitly saved via
  /// [saveChatListFiltersAsDefault]). If nothing has been saved, the chat list
  /// opens with no active filter, same as a fresh install. Also prunes any
  /// custom-group ids that no longer exist — this runs after
  /// [CustomGroupsSvc] has already loaded (see [CustomGroupsService.init]),
  /// unlike [pruneStaleCustomGroupIds]'s other call site during that same
  /// boot sequence, which runs before this filter is loaded and so has
  /// nothing yet to prune.
  void _loadDefaultChatListFilters() {
    chatListFilters.value = savedDefaultChatListFilters;
    pruneStaleCustomGroupIds();
  }

  /// Persists the current [chatListFilters] selection as the default applied on
  /// every future launch, overriding whatever was previously saved. If nothing
  /// is actively filtered (every dimension at its default value), clears the
  /// saved default instead, since there's nothing meaningful to restore.
  void saveChatListFiltersAsDefault() {
    final filters = chatListFilters.value;
    SettingsSvc.settings.savedChatFilters.value = filters.hasActiveFilter ? filters.toSettingsMap() : {};
    unawaited(SettingsSvc.settings.saveOneAsync('savedChatFilters'));
  }

  /// Drops any [ChatListFilters.customGroupIds] that no longer correspond to
  /// an existing [CustomGroup] (e.g. the group was deleted). Called once at
  /// boot (after [CustomGroupsSvc] has loaded) and every time
  /// [CustomGroupsSvc] refreshes in response to a `custom-groups-updated`
  /// event, so a deleted group's id can never sit "active" in the filter.
  void pruneStaleCustomGroupIds() {
    final validIds = CustomGroupsSvc.groups.map((g) => g.id!).toSet();
    final current = chatListFilters.value;
    final pruned = current.customGroupIds.intersection(validIds);
    if (pruned.length != current.customGroupIds.length) {
      chatListFilters.value = current.copyWith(customGroupIds: pruned);
    }
  }

  /// Set up global listeners for redacted mode settings that update all chat states
  void _setupRedactedModeListeners() {
    // Cancel existing listeners if any
    _redactedModeListener?.cancel();
    _hideContactInfoListener?.cancel();
    _generateFakeAvatarsListener?.cancel();
    _hideAttachmentsListener?.cancel();

    // Listen to redacted mode master toggle - when enabled, redact all chats; when disabled, unredact all
    _redactedModeListener = SettingsSvc.settings.redactedMode.listen((enabled) {
      for (final chatState in chatStates.values) {
        if (enabled) {
          chatState.redactFields();
        } else {
          chatState.unredactFields();
        }
      }
    });

    // Listen to hideContactInfo toggle - only affects contact info fields
    _hideContactInfoListener = SettingsSvc.settings.hideContactInfo.listen((enabled) {
      for (final chatState in chatStates.values) {
        if (enabled) {
          chatState.redactContactInfo();
        } else {
          chatState.unredactContactInfo();
        }
      }
    });

    // Listen to generateFakeAvatars toggle - only affects avatar field
    _generateFakeAvatarsListener = SettingsSvc.settings.generateFakeAvatars.listen((enabled) {
      for (final chatState in chatStates.values) {
        if (enabled) {
          chatState.redactAvatars();
        } else {
          chatState.unredactAvatars();
        }
      }
    });

    // Listen to hideAttachments toggle - updates shouldHideAttachments on all chat states
    _hideAttachmentsListener = SettingsSvc.settings.hideAttachments.listen((enabled) {
      final rm = SettingsSvc.settings.redactedMode.value;
      for (final chatState in chatStates.values) {
        chatState.updateShouldHideAttachmentsInternal(rm && enabled);
      }
    });
  }

  /// Recalculate the global unread count based on all chat states
  void _recalculateUnreadCount() {
    _syncLogicalPresentationState();
    final definition = _logicalDefinition;
    final count = definition == null
        ? chatStates.values.where((state) => state.hasUnreadMessage.value).length
        : chatStates.values
                  .where(
                    (state) =>
                        !definition.containsSourceRowId(state.chat.originalROWID) && state.hasUnreadMessage.value,
                  )
                  .length +
              (LogicalConversationViewPolicy.logicalUnread(
                    _logicalSourceChats(definition).map((chat) => chat.hasUnreadMessage ?? false),
                  )
                  ? 1
                  : 0);
    if (unreadCount.value != count) {
      unreadCount.value = count;
    }
  }

  /// Schedule a debounced update to chatListVersion to prevent rapid UI rebuilds
  /// Debounces updates by 150ms - if multiple updates occur in rapid succession,
  /// only the last one will trigger a UI rebuild
  /// If [immediate] is true, bypasses debouncing and updates immediately (for new messages)
  void _scheduleListVersionUpdate({bool immediate = false}) {
    if (immediate) {
      _listVersionUpdateTimer?.cancel();
      chatListVersion.value++;
    } else {
      _listVersionUpdateTimer?.cancel();
      _listVersionUpdateTimer = Timer(const Duration(milliseconds: 250), () {
        chatListVersion.value++;
      });
    }
  }

  /// Re-sort [_sortedChats] in-place and notify the chat list UI.
  ///
  /// Call this after bulk pin-index changes that were applied outside of the
  /// normal [updateChat] / [_repositionChat] path (e.g. pinned-order panel).
  /// The UI notification is deferred to the next frame so this is safe to call
  /// from [State.dispose] (while the widget tree may still be locked).
  void refreshSortOrder() {
    _sortedChats.sort(_sortCompare);
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduleListVersionUpdate(immediate: true);
    });
  }

  void close() {
    countSub?.cancel();
    _listVersionUpdateTimer?.cancel();
    _redactedModeListener?.cancel();
    _hideContactInfoListener?.cancel();
    _generateFakeAvatarsListener?.cancel();
    _hideAttachmentsListener?.cancel();
    _customGroupsListener?.cancel();
  }

  /// Get sorted chats (pin index first, then by latest message date)
  /// Returns the pre-sorted list - sorting is maintained on add/update
  List<Chat> getSortedChats() {
    return _projectLogicalChatList(_sortedChats);
  }

  /// State-aware sort comparison used by [_findInsertionIndex] and [refreshSortOrder].
  ///
  /// Mirrors [Chat.sort] for pin-index ordering but resolves the latest-message
  /// date from [chatStates] instead of [Chat.dbOnlyLatestMessageDate].  Using the
  /// reactive state avoids a race condition where the DB write for the new message
  /// has not yet completed when the chat list needs to be repositioned.
  int _sortCompare(Chat a, Chat b) {
    final aIsPinned = a.isPinned ?? false;
    final bIsPinned = b.isPinned ?? false;

    // Both pinned with an explicit order → sort by pinIndex.
    if (aIsPinned && bIsPinned && a.pinIndex != null && b.pinIndex != null) {
      return a.pinIndex!.compareTo(b.pinIndex!);
    }

    // b is ordered-pinned, a is not → b comes first.
    if (bIsPinned && b.pinIndex != null && (!aIsPinned || a.pinIndex == null)) {
      return 1;
    }
    // a is ordered-pinned, b is not → a comes first.
    if (aIsPinned && a.pinIndex != null && (!bIsPinned || b.pinIndex == null)) {
      return -1;
    }

    // One pinned, one not.
    if (!aIsPinned && bIsPinned) return 1;
    if (aIsPinned && !bIsPinned) return -1;

    // Both unpinned (or both pinned without an index): sort by most-recent message.
    // Use ChatState latestMessage date to avoid the DB-write race condition.
    final aDate =
        chatStates[a.guid]?.latestMessage.value?.dateCreated ??
        a.dbOnlyLatestMessageDate ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final bDate =
        chatStates[b.guid]?.latestMessage.value?.dateCreated ??
        b.dbOnlyLatestMessageDate ??
        DateTime.fromMillisecondsSinceEpoch(0);
    return -aDate.compareTo(bDate);
  }

  /// Find the correct insertion index for a chat using binary search
  /// Returns the index where the chat should be inserted to maintain sort order
  int _findInsertionIndex(Chat chat) {
    int left = 0;
    int right = _sortedChats.length;

    while (left < right) {
      final mid = (left + right) ~/ 2;
      final midChat = _sortedChats[mid];
      final comparison = _sortCompare(chat, midChat);

      if (comparison < 0) {
        right = mid;
      } else {
        left = mid + 1;
      }
    }

    return left;
  }

  /// Insert a chat into the sorted list at the correct position
  void _insertChatSorted(Chat chat) {
    final index = _findInsertionIndex(chat);
    _sortedChats.insert(index, chat);
  }

  /// Reposition a chat in the sorted list (used when chat is updated)
  /// If [immediate] is true, UI updates immediately; otherwise debounced (default: true for new messages)
  void _repositionChat(Chat chat, {bool immediate = true}) {
    // Find current position
    final currentIndex = _sortedChats.indexWhere((c) => c.guid == chat.guid);

    if (currentIndex == -1) {
      // Chat not found, just insert it
      _insertChatSorted(chat);
      return;
    }

    // Find where it should be (excluding current position)
    _sortedChats.removeAt(currentIndex);
    final newIndex = _findInsertionIndex(chat);

    // Only reposition if the index actually changed
    if (newIndex != currentIndex) {
      _sortedChats.insert(newIndex, chat);
      // Schedule UI rebuild (immediate for new messages, debounced for batch loads)
      _scheduleListVersionUpdate(immediate: immediate);
    } else {
      // Put it back in the same position
      _sortedChats.insert(currentIndex, chat);
    }
  }

  bool _logicalAuthorityShapeChanged(ChatState state, Chat updated) {
    final current = state.chat;
    if (current.originalROWID != updated.originalROWID ||
        current.guid != updated.guid ||
        current.chatIdentifier != updated.chatIdentifier ||
        current.style != updated.style ||
        current.dateDeleted != updated.dateDeleted) {
      return true;
    }
    final updatedHandles = updated.handles.isNotEmpty ? updated.handles.toList() : updated.participants;
    if (updatedHandles.isEmpty) return false;
    final currentParticipants = state.participants
        .map((participant) => '${participant.handle.address}\u0000${participant.handle.service}')
        .toSet();
    final nextParticipants = updatedHandles.map((handle) => '${handle.address}\u0000${handle.service}').toSet();
    return !setEquals(currentParticipants, nextParticipants);
  }

  bool updateChat(Chat updated, {bool override = false, bool immediate = true}) {
    if (headless) return false;

    final state = chatStates[updated.guid];
    if (state != null) {
      if (isApprovedLogicalSource(updated) && _logicalAuthorityShapeChanged(state, updated)) {
        invalidateLogicalAuthority('LOGICAL_SOURCE_AUTHORITY_SHAPE_CHANGED');
      }
      final currentLatestMessage = state.latestMessage.value;
      final currentPinIndex = state.pinIndex.value;
      final currentIsPinned = state.isPinned.value;

      // Check if sort-order-relevant fields have changed
      final latestMessageChanged =
          updated.dbLatestMessage.target?.guid != currentLatestMessage?.guid ||
          updated.dbOnlyLatestMessageDate != currentLatestMessage?.dateCreated;
      final latestMessageTimestampChanged = updated.dbOnlyLatestMessageDate != currentLatestMessage?.dateCreated;
      final pinIndexChanged = updated.pinIndex != currentPinIndex;
      final isPinnedChanged = (updated.isPinned ?? false) != currentIsPinned;
      final sortOrderChanged =
          latestMessageChanged || latestMessageTimestampChanged || pinIndexChanged || isPinnedChanged;

      if (updated != state.chat || override) {
        state.updateFromChat(updated);
      }

      if (sortOrderChanged || override) {
        _repositionChat(state.chat, immediate: immediate);
      }

      _refreshLogicalPresentation(immediate: immediate);

      return true;
    }

    return false;
  }

  void updateChats(List<Chat> updatedChats, {bool override = false}) {
    for (Chat c in updatedChats) {
      updateChat(c, override: override);
    }
  }

  Future<void> addChat(Chat toAdd, {bool immediate = false}) async {
    if (headless) return;
    // Any newly observed physical chat can be a route candidate. Conservatively
    // invalidate admission state until a forced provider observation proves it.
    invalidateLogicalAuthority('PHYSICAL_CHAT_CANDIDATE_OBSERVED');
    // Check if chat already exists
    if (chatStates.containsKey(toAdd.guid)) {
      // Update existing chat instead (debounced during init, immediate for new chats)
      updateChat(toAdd, override: true, immediate: immediate);
      return;
    }

    // Create new ChatState and add to map
    chatStates[toAdd.guid] = ChatState(toAdd);
    _setupChatStateListeners(chatStates[toAdd.guid]!);

    // Insert into sorted list at correct position
    _insertChatSorted(toAdd);

    _refreshLogicalPresentation(immediate: immediate);

    // _sortedChats isn't reactive; bump the list version so the UI rebuilds.
    _scheduleListVersionUpdate(immediate: immediate);
  }

  void removeChat(Chat toRemove) {
    if (headless) return;
    invalidateLogicalAuthority('PHYSICAL_CHAT_REMOVAL_OBSERVED');
    if (isApprovedLogicalSource(toRemove)) return;
    chatStates.remove(toRemove.guid);
    _sortedChats.removeWhere((c) => c.guid == toRemove.guid);
    _scheduleListVersionUpdate(immediate: true);
  }

  /// Marks unread chats as read. When [chatGuids] is provided, only chats in
  /// that set are affected (e.g. the currently filtered/visible subset) —
  /// otherwise every unread chat is marked, regardless of any active filter.
  Future<void> markAllAsRead({Set<String>? chatGuids}) async {
    try {
      // Phase 1: instant UI update from in-memory state — no DB query needed
      final unreadStates = chatStates.values
          .where(
            (s) =>
                !isApprovedLogicalSource(s.chat) &&
                s.hasUnreadMessage.value &&
                (chatGuids == null || chatGuids.contains(s.chat.guid)),
          )
          .toList();
      final chatIds = <int>[];

      for (final state in unreadStates) {
        state.hasUnreadMessage.value = false;
        final id = state.chat.id;
        if (id != null) {
          chatIds.add(id);
          if (!kIsDesktop && !kIsWeb) {
            MethodChannelSvc.actions.deleteNotification(notificationId: id, tag: NotificationsService.NEW_MESSAGE_TAG);
          }
        }
      }

      if (chatIds.isEmpty) return;

      // Phase 2: DB write + HTTP calls dispatched to background isolate
      final shouldMark =
          SettingsSvc.settings.enablePrivateAPI.value && SettingsSvc.settings.privateMarkChatAsRead.value;
      await ChatInterface.markAllChatsRead(chatIds: chatIds, shouldMarkOnServer: shouldMark);
    } catch (e, stack) {
      Logger.error("Error marking all chats as read", error: e, trace: stack, tag: "ChatsService");
      showToast("Failed to mark all chats as read!");
    }
  }

  void updateChatPinIndex(int oldIndex, int newIndex) {
    final chatList = getSortedChats();
    final items = List<Chat>.from(chatList.where((c) => (c.pinIndex ?? -1) >= 0));
    items.sort((a, b) => (a.pinIndex ?? 0).compareTo(b.pinIndex ?? 0));

    final item = items[oldIndex];

    // Remove the item at the old index, and re-add it at the newIndex
    // We dynamically subtract 1 from the new index depending on if the newIndex is > the oldIndex
    items.removeAt(oldIndex);
    items.insert(newIndex + (oldIndex < newIndex ? -1 : 0), item);

    // Move the pinIndex for each of the chats, and save the pinIndex in the DB
    items.forEachIndexed((i, e) async {
      e.pinIndex = i;
      await e.saveAsync(updatePinIndex: true);

      // Update chat state
      final state = chatStates[e.guid];
      if (state != null) {
        state.pinIndex.value = i;
      }
    });
  }

  void removePinIndices() {
    final chatList = getSortedChats();
    // Create a snapshot to avoid concurrent modification during iteration
    final pinnedChats = List<Chat>.from(chatList.where((c) => (c.pinIndex ?? -1) >= 0 && c.pinIndex != null));
    for (var element in pinnedChats) {
      element.pinIndex = null;
      element.saveAsync(updatePinIndex: true);

      // Update chat state
      final state = chatStates[element.guid];
      if (state != null) {
        state.pinIndex.value = null;
      }

      // Trigger reposition to re-sort the chat
      _repositionChat(element, immediate: true);
    }
  }

  Future<void> updateShareTargets() async {
    if (Platform.isAndroid) {
      StartupTasks.waitForUI().then((_) async {
        // Create a snapshot to avoid concurrent modification during iteration
        final chatList = getSortedChats();
        final chatSnapshot = chatList.where((e) => !isNullOrEmpty(e.displayName ?? e.chatIdentifier)).take(4).toList();
        for (Chat c in chatSnapshot) {
          await MethodChannelSvc.actions.pushShareTarget(
            title: c.getTitle(),
            guid: c.guid,
            icon: await avatarAsBytes(chat: c, quality: 256),
          );
        }
      });
    }
  }

  /// Fetch chat information from the server
  Future<Chat?> fetchChat(String chatGuid, {withParticipants = true, withLastMessage = false}) async {
    Logger.info("Fetching full chat metadata from server.", tag: "Fetch-Chat");

    final withQuery = <String>[];
    if (withParticipants) withQuery.add("participants");
    if (withLastMessage) withQuery.add("lastmessage");

    final response = await HttpSvc.chat.fetchOne(chatGuid, withQuery: withQuery.join(",")).catchError((err, stack) {
      Logger.error("Failed to fetch chat metadata!", error: err, trace: stack, tag: "Fetch-Chat");
      return Response(requestOptions: RequestOptions(path: ''));
    });

    if (response.statusCode == 200 && response.data["data"] != null) {
      Map<String, dynamic> chatData = response.data["data"];

      Logger.info("Got updated chat metadata from server. Saving.", tag: "Fetch-Chat");
      return (await ChatInterface.bulkSyncChats(chatsData: [chatData])).chats.first;
    }

    return null;
  }

  Future<List<Chat>> getChats({
    bool withParticipants = false,
    bool withLastMessage = false,
    int offset = 0,
    int limit = 100,
  }) async {
    final withQuery = <String>[];
    if (withParticipants) withQuery.add("participants");
    if (withLastMessage) withQuery.add("lastmessage");

    final response = await HttpSvc.chat
        .query(withQuery: withQuery, offset: offset, limit: limit, sort: withLastMessage ? "lastmessage" : null)
        .catchError((err, stack) {
          Logger.error("Failed to fetch chats!", error: err, trace: stack, tag: "Fetch-Chat");
          return Response(requestOptions: RequestOptions(path: ''));
        });

    // parse chats from the response
    final chats = <Chat>[];
    for (var item in response.data["data"]) {
      try {
        var chat = Chat.fromMap(item);
        chats.add(chat);
      } catch (ex) {
        chats.add(Chat(guid: "ERROR", displayName: item.toString()));
      }
    }

    return chats;
  }

  Future<void> _backfillApprovedLogicalSourceRows() async {
    if (kIsWeb) return;
    final query = Database.chats
        .query(Chat_.originalROWID.oneOf(LogicalConversationViewPolicy.comcastNodeUpdates.sourceChatRowIds.toList()))
        .build();
    final existingCount = query.count();
    query.close();
    if (existingCount == LogicalConversationViewPolicy.comcastNodeUpdates.sourceChatRowIds.length) {
      return;
    }

    const maxPages = 100;
    for (var page = 0; page < maxPages; page++) {
      try {
        final response = await HttpSvc.chat.query(
          withQuery: const ['participants', 'lastmessage'],
          offset: page * batchSize,
          limit: batchSize,
        );
        final rawPage = response.data?['data'];
        if (rawPage is! List) return;
        final approved = rawPage
            .whereType<Map>()
            .map((item) => item.cast<String, dynamic>())
            .where(
              (item) => LogicalConversationViewPolicy.isApprovedSourceRowId((item['originalROWID'] as num?)?.toInt()),
            )
            .toList();
        if (approved.isNotEmpty) {
          await ChatInterface.bulkSyncChats(chatsData: approved);
        }

        final refreshedQuery = Database.chats
            .query(
              Chat_.originalROWID.oneOf(LogicalConversationViewPolicy.comcastNodeUpdates.sourceChatRowIds.toList()),
            )
            .build();
        final refreshedCount = refreshedQuery.count();
        refreshedQuery.close();
        if (refreshedCount == LogicalConversationViewPolicy.comcastNodeUpdates.sourceChatRowIds.length) {
          return;
        }
        if (rawPage.length < batchSize) return;
      } catch (error, stack) {
        Logger.warn(
          'Logical source provenance backfill unavailable; projection remains fail closed',
          error: error,
          trace: stack,
          tag: 'LogicalConversationView',
        );
        return;
      }
    }
  }

  Future<List<dynamic>> getMessages(
    String guid, {
    bool withAttachment = true,
    bool withHandle = true,
    int offset = 0,
    int limit = 25,
    String sort = "DESC",
    int? after,
    int? before,
  }) async {
    Completer<List<dynamic>> completer = Completer();
    final withQuery = <String>["message.attributedBody", "message.messageSummaryInfo", "message.payloadData"];
    if (withAttachment) withQuery.add("attachment");
    if (withHandle) withQuery.add("handle");

    HttpSvc.chat
        .getMessages(
          guid,
          withQuery: withQuery.join(","),
          offset: offset,
          limit: limit,
          sort: sort,
          after: after,
          before: before,
        )
        .then((response) {
          if (!completer.isCompleted) completer.complete(response.data["data"]);
        })
        .catchError((err) {
          late final dynamic error;
          if (err is Response) {
            error = err.data["error"]["message"];
          } else {
            error = err.toString();
          }
          if (!completer.isCompleted) completer.completeError(error);
        });

    return completer.future;
  }

  /// Fetches enough records from each approved physical source to satisfy a
  /// page in the merged chronology, then persists every record against its
  /// original chat. No synthetic chat or rewritten provenance is introduced.
  Future<void> hydrateLogicalMessageSources(Chat chat, {required int offset, required int limit}) {
    return _withLogicalHydrationLock(() => _hydrateLogicalMessageSources(chat, offset: offset, limit: limit));
  }

  Future<void> _withLogicalHydrationLock(Future<void> Function() operation) async {
    while (_logicalHydrationMutex != null) {
      await _logicalHydrationMutex!.future;
    }
    final mutex = Completer<void>();
    _logicalHydrationMutex = mutex;
    try {
      await operation();
    } finally {
      if (identical(_logicalHydrationMutex, mutex)) _logicalHydrationMutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }

  Future<void> _hydrateLogicalMessageSources(Chat chat, {required int offset, required int limit}) async {
    final sources = logicalSourceChatsFor(chat);
    if (sources.length == 1) return;
    final definition = _logicalDefinition;
    if (definition == null) return;
    final requiredDepth = offset + limit;
    for (final source in sources) {
      final authorityRevision = currentLogicalAuthorityRevision?.authorityRevision ?? 'UNOBSERVED_AUTHORITY';
      final sourceEventWatermark = _logicalSourceEventWatermarks[source.guid] ?? 0;
      final memberBindingDigest = sha256.convert(utf8.encode('${source.originalROWID}\u0000${source.guid}')).toString();
      final identity = LogicalProjectionCacheIdentity(
        logicalId: definition.id,
        certificateRevision: definition.revision,
        memberBindingDigest: memberBindingDigest,
        authorityRevision: authorityRevision,
        sourceWatermarks: const <String, String>{},
        eventWatermark: sourceEventWatermark,
      );
      final key = '${definition.id}:${source.guid}';
      final cursor = _logicalHydrationCursors.putIfAbsent(key, () {
        return _LogicalSourceHydrationCursor()
          ..identity = identity
          ..eventWatermark = sourceEventWatermark;
      });
      final existingIdentity = cursor.identity;
      if (existingIdentity == null ||
          !existingIdentity.isCompatibleWith(identity) ||
          existingIdentity.authorityRevision != identity.authorityRevision ||
          cursor.eventWatermark != sourceEventWatermark) {
        cursor.reset(toEventWatermark: sourceEventWatermark);
        cursor.identity = identity;
      }
      if (cursor.nextOffset > 0) {
        final expectedLocalDepth = cursor.providerTotal == null || cursor.providerTotal! > cursor.nextOffset
            ? cursor.nextOffset
            : cursor.providerTotal!;
        if (_logicalLocalSourceMessageCount(source) < expectedLocalDepth) {
          cursor.reset(toEventWatermark: sourceEventWatermark);
        }
      }

      if (cursor.nextOffset > 0) {
        final snapshots = await Future.wait([
          HttpSvc.chat.getMessages(source.guid, offset: 0, limit: 1),
          HttpSvc.chat.getMessages(source.guid, offset: cursor.nextOffset - 1, limit: 1),
        ]);
        final headResponse = snapshots[0];
        final tailResponse = snapshots[1];
        final headPage = headResponse.data?['data'];
        final headMetadata = headResponse.data?['metadata'];
        final tailPage = tailResponse.data?['data'];
        final tailMetadata = tailResponse.data?['metadata'];
        if (headPage is! List ||
            headMetadata is! Map ||
            headPage.length > 1 ||
            tailPage is! List ||
            tailMetadata is! Map ||
            tailPage.length != 1) {
          throw StateError('LOGICAL_SOURCE_WATERMARK_UNAVAILABLE');
        }
        final total = (headMetadata['total'] as num?)?.toInt();
        final tailTotal = (tailMetadata['total'] as num?)?.toInt();
        final head = headPage.firstOrNull;
        final tail = tailPage.single;
        final headGuid = head is Map ? head['guid']?.toString() : null;
        final headRowId = head is Map ? (head['originalROWID'] as num?)?.toInt() : null;
        final tailGuid = tail is Map ? tail['guid']?.toString() : null;
        final tailRowId = tail is Map ? (tail['originalROWID'] as num?)?.toInt() : null;
        if (total == null ||
            tailTotal != total ||
            total != cursor.providerTotal ||
            headGuid != cursor.headGuid ||
            headRowId != cursor.headRowId ||
            tailGuid != cursor.tailGuid ||
            tailRowId != cursor.tailRowId) {
          cursor.reset(toEventWatermark: sourceEventWatermark);
        }
      }

      while (!cursor.exhausted && cursor.nextOffset < requiredDepth) {
        final pageLimit = (requiredDepth - cursor.nextOffset).clamp(1, limit);
        final response = await HttpSvc.chat.getMessages(
          source.guid,
          withQuery: 'message.attributedBody,message.messageSummaryInfo,message.payloadData,attachment,handle',
          offset: cursor.nextOffset,
          limit: pageLimit,
        );
        final rawPage = response.data?['data'];
        final rawMetadata = response.data?['metadata'];
        if (rawPage is! List || rawMetadata is! Map) {
          throw StateError('LOGICAL_SOURCE_PAGE_UNAVAILABLE');
        }
        final page = rawPage.whereType<Map>().map((item) => item.cast<String, dynamic>()).toList();
        final total = (rawMetadata['total'] as num?)?.toInt();
        final count = (rawMetadata['count'] as num?)?.toInt();
        if (page.length != rawPage.length || total == null || count != page.length) {
          throw StateError('LOGICAL_SOURCE_PAGE_MALFORMED');
        }
        if (total < cursor.nextOffset) {
          cursor.reset(toEventWatermark: sourceEventWatermark);
          continue;
        }
        final expectedPageLength = (total - cursor.nextOffset).clamp(0, pageLimit);
        if (page.length != expectedPageLength) {
          throw StateError('LOGICAL_SOURCE_PAGE_TRUNCATED');
        }
        if (cursor.nextOffset == 0) {
          final head = page.firstOrNull;
          cursor.providerTotal = total;
          cursor.headGuid = head?['guid']?.toString();
          cursor.headRowId = (head?['originalROWID'] as num?)?.toInt();
        } else if (cursor.providerTotal != total) {
          cursor.reset();
          continue;
        }
        if (page.isNotEmpty) {
          await SyncInterface.bulkSyncData(chatData: source.toMap(), messagesData: page);
          final tail = page.last;
          cursor.tailGuid = tail['guid']?.toString();
          cursor.tailRowId = (tail['originalROWID'] as num?)?.toInt();
        }
        cursor.nextOffset += page.length;
        cursor.exhausted = page.length < pageLimit || cursor.nextOffset >= total;
        cursor.identity = LogicalProjectionCacheIdentity(
          logicalId: definition.id,
          certificateRevision: definition.revision,
          memberBindingDigest: memberBindingDigest,
          authorityRevision: authorityRevision,
          sourceWatermarks: <String, String>{
            source.guid:
                '${cursor.providerTotal ?? -1}:${cursor.headRowId ?? -1}:${cursor.headGuid ?? ''}:'
                '${cursor.tailRowId ?? -1}:${cursor.tailGuid ?? ''}',
          },
          eventWatermark: sourceEventWatermark,
        );
        if (page.isEmpty) break;
      }
      if (cursor.nextOffset > 0) {
        final postFetchBoundary = await _logicalSourceBoundarySnapshot(source, cursor.nextOffset);
        if (postFetchBoundary.total != cursor.providerTotal ||
            postFetchBoundary.headGuid != cursor.headGuid ||
            postFetchBoundary.headRowId != cursor.headRowId ||
            postFetchBoundary.tailGuid != cursor.tailGuid ||
            postFetchBoundary.tailRowId != cursor.tailRowId) {
          cursor.reset(toEventWatermark: sourceEventWatermark);
          throw StateError('LOGICAL_SOURCE_SNAPSHOT_CHANGED_DURING_HYDRATION');
        }
      }
    }
  }

  Future<({int total, String? headGuid, int? headRowId, String tailGuid, int tailRowId})>
  _logicalSourceBoundarySnapshot(Chat source, int consumedDepth) async {
    final snapshots = await Future.wait([
      HttpSvc.chat.getMessages(source.guid, offset: 0, limit: 1),
      HttpSvc.chat.getMessages(source.guid, offset: consumedDepth - 1, limit: 1),
    ]);
    final headPage = snapshots[0].data?['data'];
    final headMetadata = snapshots[0].data?['metadata'];
    final tailPage = snapshots[1].data?['data'];
    final tailMetadata = snapshots[1].data?['metadata'];
    if (headPage is! List || headPage.length > 1 || headMetadata is! Map || tailPage is! List || tailPage.length != 1) {
      throw StateError('LOGICAL_SOURCE_WATERMARK_UNAVAILABLE');
    }
    final total = (headMetadata['total'] as num?)?.toInt();
    final tailTotal = tailMetadata is Map ? (tailMetadata['total'] as num?)?.toInt() : null;
    final head = headPage.firstOrNull;
    final tail = tailPage.single;
    final headGuid = head is Map ? head['guid']?.toString() : null;
    final headRowId = head is Map ? (head['originalROWID'] as num?)?.toInt() : null;
    final tailGuid = tail is Map ? tail['guid']?.toString() : null;
    final tailRowId = tail is Map ? (tail['originalROWID'] as num?)?.toInt() : null;
    if (total == null || tailTotal != total || tailGuid == null || tailRowId == null) {
      throw StateError('LOGICAL_SOURCE_WATERMARK_UNAVAILABLE');
    }
    return (total: total, headGuid: headGuid, headRowId: headRowId, tailGuid: tailGuid, tailRowId: tailRowId);
  }

  int _logicalLocalSourceMessageCount(Chat source) {
    if (kIsWeb || source.id == null) return 0;
    final query = (Database.messages.query(
      Message_.dateDeleted.isNull(),
    )..link(Message_.chat, Chat_.id.equals(source.id!))).build();
    final count = query.count();
    query.close();
    return count;
  }

  // ========== Chat Lifecycle Management Methods (migrated from ChatManager) ==========

  /// Set all chats to inactive synchronously
  void setAllInactiveSync({bool save = true, bool clearActive = true}) {
    Logger.debug('Setting chats to inactive (save: $save, clearActive: $clearActive)');

    String? skip;
    if (clearActive) {
      activeChat?.controller = null;
      activeChat = null;
    } else {
      skip = activeChat?.chat.guid;
    }

    chatStates.forEach((key, state) {
      if (key == skip) return;
      state.updateActiveInternal(false);
      state.updateAliveInternal(false);
    });

    if (save) {
      unawaited(PrefsSvc.messaging.clearLastOpenedChat());
    }
  }

  /// Set all chats to inactive asynchronously
  Future<void> setAllInactive() async {
    Logger.debug('Setting all chats to inactive');
    await PrefsSvc.messaging.clearLastOpenedChat();
    setAllInactiveSync(save: false);
  }

  /// Set a chat as the active chat
  Future<void> setActiveChat(Chat chat, {bool clearNotifications = true}) async {
    chat = presentationChatFor(chat);
    await PrefsSvc.messaging.setLastOpenedChat(chat.guid);
    setActiveChatSync(chat, clearNotifications: clearNotifications, save: false);
  }

  /// Set a chat as the active chat synchronously
  void setActiveChatSync(Chat chat, {bool clearNotifications = true, bool save = true}) {
    chat = presentationChatFor(chat);
    Logger.debug('Setting active chat to ${chat.guid} (${chat.displayName})');

    // Get or create the chat state
    final chatState = getOrCreateChatState(chat);

    // Set this chat as active
    activeChat = chatState;
    chatState.updateActiveAndAliveInternal(true);

    // Clear all other chats to inactive
    setAllInactiveSync(save: false, clearActive: false);

    if (clearNotifications && !isLogicalConversation(chat)) {
      // Defer the observable update to avoid updating during build phase
      Future.microtask(() {
        setChatHasUnread(chatState.chat, false, force: true);
      });
    }

    if (save) {
      unawaited(PrefsSvc.messaging.setLastOpenedChat(chat.guid));
    }
  }

  /// Set the active chat to dead (not alive)
  void setActiveToDead() {
    Logger.debug('Setting active chat to dead: ${activeChat?.chat.guid}');
    activeChat?.updateAliveInternal(false);
  }

  /// Set the active chat to alive
  void setActiveToAlive() {
    Logger.info('Setting active chat to alive: ${activeChat?.chat.guid}');
    activeChat?.updateAliveInternal(true);
  }

  /// Check if a chat is currently active (both active and alive)
  bool isChatActive(String guid) {
    final state = getChatState(presentationGuidFor(guid));
    return state?.isChatActive ?? false;
  }

  /// Get the chat controller for a specific chat
  ChatState? getChatController(String guid) {
    return getChatState(guid);
  }

  // ========== End Chat Lifecycle Management ==========

  // ========== Chat Operations with Service Orchestration ==========

  /// Get chat count
  int? getChatCount() {
    return Database.chats.count();
  }

  /// Delete a chat with full UI cleanup and service state management.
  /// Set [deleteHandles] to true to also remove the chat's participant handles.
  Future<void> deleteChat(Chat chat, {bool deleteHandles = false}) async {
    if (kIsWeb) return;
    if (isApprovedLogicalSource(chat)) return;

    // Handle active chat cleanup
    if (activeChat?.chat.guid == chat.guid) {
      NavigationSvc.closeAllConversationView(Get.context!);
      await setAllInactive();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Collect handle IDs before deleting the chat (handles are lazy-loaded via ToMany).
    // Only include handles that are not shared with any other chat — if a handle
    // participates in multiple chats, removing it would break those other chats.
    List<int> handleIds = <int>[];
    if (deleteHandles) {
      final otherChats = allChats.where((c) => c.guid != chat.guid).toList();
      final otherHandleIds = otherChats.expand((c) => c.handles).map((h) => h.id).whereType<int>().toSet();
      handleIds = chat.handles.map((e) => e.id).whereType<int>().where((id) => !otherHandleIds.contains(id)).toList();
    }

    // Perform the actual DB deletion
    List<Message> messages = Chat.getMessages(chat);
    await ChatInterface.deleteChat(
      chatId: chat.id!,
      messageIds: messages.map((e) => e.id!).toList(),
      handleIds: handleIds,
    );

    // Remove from service state
    removeChat(chat);
  }

  /// Performs a full messaging reset: wipes all Messages, Attachments, Chats,
  /// Handles, and Contacts (ContactV2) from the database, deletes all
  /// associated files from disk, and flushes every in-memory service cache
  /// tied to that data.
  ///
  /// Does NOT touch Settings, themes, FCM data, or scheduled messages. Does
  /// NOT show any confirmation UI — callers must confirm with the user
  /// before invoking this.
  Future<void> deleteAllMessagingData() async {
    if (kIsWeb) return;

    // Close any active conversation view first (mirrors deleteChat() above).
    if (activeChat != null) {
      NavigationSvc.closeAllConversationView(Get.context!);
      setAllInactive();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Capture currently-registered per-chat MessagesService tags before
    // init() below clears chatStates — it's our only enumeration source.
    final chatGuids = chatStates.keys.toList();

    Database.resetMessagingData();
    await _deleteMessagingFiles();

    for (final guid in chatGuids) {
      maybeFindMessagesSvc(guid)?.close(force: true);
    }
    AttachmentsSvc.clearVideoThumbnailCache();
    HandleSvc.reset();

    // Use init() rather than reset() so the empty-database case is handled
    // correctly: reset() alone leaves loadedFirstChatBatch=false forever since
    // there are no chats left to trigger the "batch loaded" codepath, which
    // left the conversation list stuck on "Loading chats..." indefinitely.
    // init(force: true) calls reset() internally and then, for a zero-chat
    // database, sets loadedFirstChatBatch=true and re-initializes DB watchers
    // (same codepath FullSyncManager.complete() uses after a full resync).
    await init(force: true);
  }

  /// Deletes on-disk messaging data: attachments (originals/thumbnails/live-photo
  /// .mov), per-chat avatars, per-chat custom backgrounds, per-message balloon
  /// bundle directories, cached URL preview images, and cached contact avatars.
  Future<void> _deleteMessagingFiles() async {
    final paths = [
      FilesystemSvc.attachmentsPath,
      FilesystemSvc.avatarsPath,
      FilesystemSvc.customBackgroundsPath,
      FilesystemSvc.messagesPath,
      FilesystemSvc.urlPreviewsPath,
      FilesystemSvc.contactAvatarsPath,
    ];
    for (final path in paths) {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Soft delete a chat with full UI cleanup and service state management
  Future<void> softDeleteChat(Chat chat) async {
    if (kIsWeb) return;
    if (isApprovedLogicalSource(chat)) return;

    // Handle active chat cleanup
    if (activeChat?.chat.guid == chat.guid) {
      NavigationSvc.closeAllConversationView(Get.context!);
      await setAllInactive();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Perform the actual DB soft delete
    await ChatInterface.softDeleteChat(chatData: chat.toMap());
    chat.clearTranscript();

    // Propagate dateDeleted to ChatState before removing it so any live
    // listeners (e.g. ConversationTileController) can react reactively.
    getChatState(chat.guid)?.updateDateDeletedInternal(DateTime.now().toUtc());

    // Remove from service state
    removeChat(chat);
  }

  /// Undelete a chat
  Future<void> unDeleteChat(Chat chat) async {
    if (kIsWeb) return;
    if (isApprovedLogicalSource(chat)) return;
    await ChatInterface.unDeleteChat(chatData: chat.toMap());
  }

  /// Toggle chat pin status with service updates
  Future<Chat> _toggleChatPin(Chat chat, bool isPinned) async {
    // Perform DB operation
    await chat.togglePinAsync(isPinned);

    // Update service state
    updateChat(chat);

    // Pin status changes the filtered list (pinned vs non-pinned), so we must
    // explicitly trigger a list version update so all conversation list views re-filter.
    _scheduleListVersionUpdate(immediate: true);

    return chat;
  }

  /// Toggle chat archive status with service updates
  Future<Chat> _toggleChatArchive(Chat chat, bool isArchived) async {
    // Perform DB operation
    await chat.toggleArchivedAsync(isArchived);

    // Update service state
    updateChat(chat);

    // Archive status changes the filtered list (not sort order), so we must
    // explicitly trigger a list version update so all conversation list views re-filter.
    _scheduleListVersionUpdate(immediate: true);

    return chat;
  }

  /// Toggle chat unread status with active chat awareness
  Future<Chat> _toggleChatHasUnread(
    Chat chat,
    bool hasUnread, {
    bool force = false,
    bool clearLocalNotifications = true,
    bool privateMark = true,
  }) async {
    // Check if chat is active and adjust behavior
    final isActive = isChatActive(chat.guid);

    if (isActive && hasUnread && !force) {
      // Don't mark as unread if chat is active (unless forced)
      return chat;
    }

    // Determine actual parameters based on active status
    bool actualClearNotifications = clearLocalNotifications;
    bool actualPrivateMark = privateMark;
    bool actualForce = force;

    if (isActive) {
      // Force mark as read if chat is active
      actualForce = true;
      actualPrivateMark = true;
    }

    // Perform DB operation with adjusted parameters
    await chat.toggleHasUnreadAsync(
      hasUnread,
      force: actualForce,
      clearLocalNotifications: actualClearNotifications,
      privateMark: actualPrivateMark,
    );

    // Update service state
    updateChat(chat);

    return chat;
  }

  /// Add message to chat with full service orchestration
  Future<MessageSaveResult> addMessageToChat(
    Chat chat,
    Message message, {
    bool changeUnreadStatus = true,
    bool checkForMessageText = true,
    bool clearNotificationsIfFromMe = true,
  }) async {
    // Perform the DB operation to add the message
    final result = await chat.addMessage(
      message,
      changeUnreadStatus: false, // We'll handle this with service awareness
      checkForMessageText: checkForMessageText,
      clearNotificationsIfFromMe: clearNotificationsIfFromMe,
    );

    final isNewer = result.isNewer;

    // Handle service-level operations if this is a newer message
    if (isNewer) {
      // Add chat to service if it was previously deleted
      if (chat.dateDeleted != null) {
        await addChat(chat);
      } else {
        // Just update the existing chat in service
        updateChat(chat);
      }
    }

    // Handle unread status with active chat awareness
    if (checkForMessageText && changeUnreadStatus && isNewer) {
      final isActive = isChatActive(chat.guid);

      if (message.isFromMe! || isActive) {
        // Mark as read if from me or chat is active
        await _toggleChatHasUnread(
          chat,
          false,
          clearLocalNotifications: clearNotificationsIfFromMe,
          force: isActive,
          privateMark: isActive,
        );
      } else {
        // Mark as unread if not from me and chat is not active
        await _toggleChatHasUnread(chat, true, privateMark: false);
      }
    }

    return result;
  }

  // ========== Chat Property Setters ==========
  // These update both the Chat model (DB) and ChatState (UI reactivity)

  /// Set chat pinned status
  Future<void> setChatPinned(Chat chat, bool value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.isPinned.value == value) return;

    // Update DB
    await _toggleChatPin(chat, value);

    // Update state if available
    state?.updateIsPinnedInternal(value);
  }

  /// Set chat pin index
  Future<void> setChatPinIndex(Chat chat, int? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.pinIndex.value == value) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.pinIndex = value;
    await chatToUpdate.saveAsync(updatePinIndex: true);

    // Update state if available
    state?.updatePinIndexInternal(value);
  }

  /// Set chat unread status
  Future<void> setChatHasUnread(
    Chat chat,
    bool value, {
    bool force = false,
    bool clearLocalNotifications = true,
    bool privateMark = true,
  }) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.hasUnreadMessage.value == value && !force) {
      return;
    }

    // Update DB with active chat awareness
    await _toggleChatHasUnread(
      chat,
      value,
      force: force,
      clearLocalNotifications: clearLocalNotifications,
      privateMark: privateMark,
    );

    // Update state if available
    state?.updateHasUnreadInternal(value);
  }

  /// Set chat muted status
  Future<void> setChatMuted(Chat chat, bool isMuted) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    final newMuteType = isMuted ? "mute" : null;
    if (state != null && state.muteType.value == newMuteType) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    await chatToUpdate.toggleMuteAsync(isMuted);

    // Update state if available
    state?.updateMutedInternal(newMuteType, null);
  }

  /// Set chat archived status
  Future<void> setChatArchived(Chat chat, bool value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.isArchived.value == value) return;

    // Update DB
    await _toggleChatArchive(chat, value);

    // Update state if available
    state?.updateArchivedInternal(value);
  }

  /// Set chat auto send read receipts
  Future<void> setChatAutoSendReadReceipts(Chat chat, bool? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.autoSendReadReceipts.value == value) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    await chatToUpdate.toggleAutoReadAsync(value);

    // Update state if available
    state?.updateAutoSendReadReceiptsInternal(value);
  }

  /// Set chat auto send typing indicators
  Future<void> setChatAutoSendTypingIndicators(Chat chat, bool? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.autoSendTypingIndicators.value == value) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    await chatToUpdate.toggleAutoTypeAsync(value);

    // Update state if available
    state?.updateAutoSendTypingIndicatorsInternal(value);
  }

  /// Set chat lock name status
  Future<void> setChatLockName(Chat chat, bool value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.lockChatName.value == value) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.lockChatName = value;
    await chatToUpdate.saveAsync(updateLockChatName: true);

    // Update state if available
    state?.updateLockChatNameInternal(value);
  }

  /// Set chat lock icon status
  Future<void> setChatLockIcon(Chat chat, bool value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.lockChatIcon.value == value) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.lockChatIcon = value;
    await chatToUpdate.saveAsync(updateLockChatIcon: true);

    // Update state if available
    state?.updateLockChatIconInternal(value);
  }

  /// Set chat display name
  Future<void> setChatDisplayName(Chat chat, String? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.displayName.value == value) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.displayName = value;

    // Update state eagerly so the UI reflects the change immediately
    state?.updateDisplayNameInternal(value);

    await chatToUpdate.saveAsync(updateDisplayName: true);
  }

  /// Set chat custom avatar path
  Future<void> setChatCustomAvatarPath(Chat chat, String? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);
    final chatToUpdate = state?.chat ?? chat;
    final oldPath = chatToUpdate.customAvatarPath;

    if (oldPath == value) return;

    chatToUpdate.customAvatarPath = value;
    await chatToUpdate.saveAsync(updateCustomAvatarPath: true);

    // Update state if available
    state?.updateCustomAvatarPathInternal(value);

    if (!kIsWeb && oldPath != null && oldPath != value) {
      try {
        final file = File(oldPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    }
  }

  /// Set chat custom background path
  Future<void> setChatCustomBackgroundPath(Chat chat, String? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);
    final resolvedPath = value ?? FilesystemSvc.getExistingChatBackgroundPath(chat.guid);
    final oldPath = state?.customBackgroundPath.value ?? FilesystemSvc.getExistingChatBackgroundPath(chat.guid);
    if (state != null && state.customBackgroundPath.value == resolvedPath) {
      return;
    }

    if (oldPath != null && oldPath != resolvedPath) {
      ThemesService.clearAdaptiveThemeCache(oldPath);
    }

    final lightThemeName = state?.customThemeLight.value ?? chat.customThemeLight;
    final darkThemeName = state?.customThemeDark.value ?? chat.customThemeDark;
    final usesAdaptiveBackgroundTheme =
        (lightThemeName != null && ThemesService.isAdaptiveBackgroundThemeName(lightThemeName)) ||
        (darkThemeName != null && ThemesService.isAdaptiveBackgroundThemeName(darkThemeName));
    if (resolvedPath != null && usesAdaptiveBackgroundTheme) {
      await ThemesService.upsertAdaptiveBackgroundThemesFromImage(resolvedPath, scopeKey: chat.guid);
    }

    state?.updateCustomBackgroundPathInternal(resolvedPath);
  }

  /// Set the custom light and dark themes for a specific chat.
  Future<void> setChatCustomThemes(Chat chat, {String? lightTheme, String? darkTheme}) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);
    final changed =
        state == null || state.customThemeLight.value != lightTheme || state.customThemeDark.value != darkTheme;
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.customThemeLight = lightTheme;
    chatToUpdate.customThemeDark = darkTheme;
    await chatToUpdate.saveAsync(updateCustomThemes: true);

    state?.updateCustomThemeLightInternal(lightTheme);
    state?.updateCustomThemeDarkInternal(darkTheme);
    if (!changed) {
      state.bumpThemeVersion();
    }
  }

  /// Set chat latest message
  Future<void> setChatLatestMessage(Chat chat, Message value) async {
    final state = getChatState(chat.guid);
    if (state == null) return;

    // Update Chat model (use state.chat if available, otherwise use passed in chat)
    final chatToUpdate = state.chat;

    // Only save in the DB if it's not already the same latest message.
    final currentGuid = isLogicalConversation(chat)
        ? chatToUpdate.dbLatestMessage.target?.guid
        : state.latestMessage.value?.guid;
    if (currentGuid != value.guid) {
      chatToUpdate.setLatestMessage(value);
    }

    // Update state if available
    state.updateLatestMessageInternal(value);
    _refreshLogicalPresentation();
  }

  /// Update chat latest message and subtitle in response to a new or updated message.
  /// Called by IncomingMessageHandler and SyncService to keep ChatState as the single
  /// source of truth for the conversation tile subtitle.
  ///
  /// Only moves the latest-message pointer forward in time — sync can report an
  /// older delta message as a chat's latest, which would rewind its sort order.
  /// The 2s tolerance allows a temp->real GUID swap. [allowOlder] opts out for the
  /// post-deletion recompute, which must fall back to an older surviving message.
  void updateChatLatestMessage(String chatGuid, Message message, {bool allowOlder = false}) {
    final state = getChatState(chatGuid);
    if (state == null) return;

    if (!allowOlder) {
      final current = isLogicalConversation(state.chat) ? state.chat.dbLatestMessage.target : state.latestMessage.value;
      final currentDate = current?.dateCreated;
      final incomingDate = message.dateCreated;
      const staleTolerance = Duration(seconds: 2);
      if (current != null &&
          current.guid != message.guid &&
          currentDate != null &&
          currentDate.millisecondsSinceEpoch > 0 &&
          incomingDate != null &&
          incomingDate.isBefore(currentDate.subtract(staleTolerance))) {
        return;
      }
    }

    state.updateLatestMessageInternal(message);
    final redacted = SettingsSvc.settings.redactedMode.value;
    final hideContactInfo = redacted && SettingsSvc.settings.hideContactInfo.value;
    final hideMessageContent = redacted && SettingsSvc.settings.hideMessageContent.value;
    state.updateSubtitleInternal(
      message.getNotificationText(hideContactInfo: hideContactInfo, hideMessageContent: hideMessageContent),
    );
    state.chat.setLatestMessage(message);
    _repositionChat(state.chat, immediate: true);
    _refreshLogicalPresentation();
  }

  /// Set chat text field text
  /// ChatState is updated synchronously and is the source of truth for the UI.
  /// The DB write is fire-and-forget so callers never need to await this.
  Future<void> setChatTextFieldText(Chat chat, String? value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.textFieldText.value == value) return;

    // Update ChatState first — this is the source of truth for the text field UI.
    state?.updateTextFieldTextInternal(value);

    // Persist to the chat model and DB asynchronously (fire-and-forget).
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.textFieldText = value;
    unawaited(chatToUpdate.saveAsync(updateTextFieldText: true));
  }

  /// Set chat text field attachments
  /// ChatState is updated synchronously and is the source of truth for the UI.
  /// The DB write is fire-and-forget so callers never need to await this.
  Future<void> setChatTextFieldAttachments(Chat chat, List<String> value) async {
    if (isApprovedLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && listEquals(state.textFieldAttachments, value)) return;

    // Update ChatState first — this is the source of truth for the text field UI.
    state?.updateTextFieldAttachmentsInternal(value);

    // Persist to the chat model and DB asynchronously (fire-and-forget).
    final chatToUpdate = state?.chat ?? chat;
    chatToUpdate.textFieldAttachments = value;
    unawaited(chatToUpdate.saveAsync(updateTextFieldAttachments: true));
  }

  // ========== End Chat Property Setters ==========

  // ========== End Chat Operations ==========

  void reset({bool reinitWatchers = false}) {
    currentCount = 0;
    hasChats.value = false;
    _activeChat = null;
    chatStates.clear();
    _sortedChats.clear();
    loadedAllChats = Completer();
    loadedFirstChatBatch.value = false;
    webCachedHandles.clear();
    _logicalHydrationCursors.clear();
    _logicalSourceEventWatermarks.clear();

    countSub?.cancel();
    if (reinitWatchers) {
      initDbWatchers();
    }
  }
}
