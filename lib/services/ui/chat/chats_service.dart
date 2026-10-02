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
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';
import 'package:bluebubbles/services/ui/chat/logical_certificate_advancement_transaction.dart';
import 'package:bluebubbles/services/ui/chat/logical_candidate_reconciliation_context.dart';
import 'package:bluebubbles/services/ui/chat/logical_mutation_protection.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_certificate_binding.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry_binding.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_settings.dart';
import 'package:bluebubbles/services/ui/chat/logical_notification_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_platform_cleanup.dart';
import 'package:bluebubbles/services/ui/chat/logical_membership_refresh.dart';

import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';

// ignore: non_constant_identifier_names
ChatsService get ChatsSvc => GetIt.I<ChatsService>();

/// Write capability is deliberately narrower than certified read identity.
/// Only the banked Build 99 conversation may consume Comcast writer state.
enum LogicalWriterCapability { ordinary, build99Writer, certifiedReadOnly }

LogicalWriterCapability classifyLogicalWriterCapability({
  required bool isCertified,
  required bool hasBuild99WriterBinding,
}) {
  if (!isCertified) return LogicalWriterCapability.ordinary;
  return hasBuild99WriterBinding ? LogicalWriterCapability.build99Writer : LogicalWriterCapability.certifiedReadOnly;
}

class NotificationConversationRoute {
  const NotificationConversationRoute({required this.source, required this.presentation, required this.isLogical});

  final Chat source;
  final Chat presentation;
  final bool isLogical;
}

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
  final LogicalDraftSaveTransactionQueue _logicalDraftTransactions = LogicalDraftSaveTransactionQueue();
  Completer<void>? _logicalDraftAttachmentStagingMutex;
  final Map<String, int> _logicalDraftGenerations = <String, int>{};
  final RxMap<String, int> _logicalDraftPreviewRevisions = <String, int>{}.obs;
  final LogicalUnreadConversationStore _logicalUnreadStates = LogicalUnreadConversationStore();
  final LogicalOperationCoalescer<LogicalRouteDecision> _logicalMarkReadOperations =
      LogicalOperationCoalescer<LogicalRouteDecision>();
  final LogicalKeyedSerialExecutor _logicalUnreadPersistence = LogicalKeyedSerialExecutor();
  final LogicalMembershipAvailabilityTracker _logicalMembershipAvailability = LogicalMembershipAvailabilityTracker();

  /// Compatibility projections for legacy consumers. Per-conversation state
  /// in [_logicalUnreadStates] is the only source of truth.
  final Rxn<LogicalMarkReadOutcome> logicalMarkReadOutcome = Rxn<LogicalMarkReadOutcome>();
  final RxBool logicalReadSyncPending = false.obs;
  Completer<void>? _logicalHydrationMutex;
  final Map<String, _LogicalSourceHydrationCursor> _logicalHydrationCursors = <String, _LogicalSourceHydrationCursor>{};
  final Map<String, int> _logicalSourceEventWatermarks = <String, int>{};
  Timer? _logicalAuthorityRecheckTimer;
  DateTime? _logicalAuthorityRecheckDueAt;
  int _logicalPassiveSupersededRechecks = 0;
  int _logicalPassiveRecheckFailures = 0;

  LogicalAuthorityRevision? get currentLogicalAuthorityRevision => _logicalAuthorityRevisionTracker.current;

  LogicalTransportReadinessEvidence? logicalTransportReadinessForSourceRow(int sourceRowId) =>
      _logicalTransportReadinessBySourceRow[sourceRowId];

  bool isLogicalEvidenceObservationCurrent(int epoch) => _logicalEvidenceObservationEpochTracker.isCurrent(epoch);

  Future<T> _withLogicalDraftLock<T>(Future<T> Function() operation) => _logicalDraftTransactions.run(operation);

  /// Map of chat states for granular reactivity
  /// Key is the chat GUID, value is the ChatState
  /// The map itself doesn't need to be Rx because the underlying ChatState fields are
  final Map<String, ChatState> chatStates = {};

  ChatState? _activeChat;
  ChatState? get activeChat => _activeChat;
  set activeChat(ChatState? value) {
    _activeChat = value;
    final key = value == null ? null : conversationKeyFor(value.chat);
    if (activeChatGuid.value != key) activeChatGuid.value = key;
  }

  /// Reactive application conversation key of the active chat. For an ordinary
  /// conversation this remains the physical GUID, preserving existing behavior.
  /// A certified logical conversation uses its stable logical ID so a presentation
  /// member change cannot lose active-row highlighting.
  ///
  /// The historical field name is retained for source compatibility. Callers must
  /// treat the value as an opaque conversation key, never as provider provenance.
  final RxnString activeChatGuid = RxnString();

  /// Sorted list of chats maintained for efficient access
  /// Updated on add/update using binary search insertion O(log n + n)
  /// instead of sorting entire list O(n log n) on every access
  final List<Chat> _sortedChats = [];

  /// Reactive counter that increments when chat list order changes
  /// Used to trigger UI rebuilds when chats are repositioned
  final RxInt chatListVersion = 0.obs;

  LogicalConversationSettingsLedger _logicalSettings = LogicalConversationSettingsLedger.empty();
  final LogicalConversationSettingsTransactionQueue _logicalSettingsTransactions =
      LogicalConversationSettingsTransactionQueue();

  static const int _logicalCandidateQuarantineDurationMs = 15 * Duration.millisecondsPerMinute;
  LogicalCandidateQuarantineLedger _logicalCandidateQuarantine = LogicalCandidateQuarantineLedger.empty();
  Completer<void>? _logicalCandidateQuarantineMutex;
  String? _logicalCandidateQuarantinePersistedFingerprint;
  LogicalCandidateReconciliationContextLedger _logicalCandidateContexts =
      LogicalCandidateReconciliationContextLedger.empty();
  String? _logicalCandidateContextsPersistedRevision;
  Completer<void>? _logicalCandidateReconciliationMutex;
  Timer? _logicalCandidateReconciliationTimer;
  int _logicalCandidateReconciliationGeneration = 0;

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

  LogicalConversationId? _registeredLogicalIdForChat(Chat chat) =>
      LogicalConversationViewPolicy.trustedLogicalIdForSourceBinding(
        sourceChatRowId: chat.originalROWID,
        sourceChatGuid: chat.guid,
      );
  LogicalConversationReadCertificate? _registeredCertificateForChat(Chat chat) {
    final logicalId = _registeredLogicalIdForChat(chat);
    return logicalId == null ? null : LogicalConversationViewPolicy.certificateForLogicalId(logicalId);
  }

  List<Chat> _registeredLogicalChats() {
    if (LogicalConversationViewPolicy.activeAuthorities.isEmpty) return const <Chat>[];
    final registeredRows = LogicalConversationViewPolicy.approvedSourceRowIds;
    if (registeredRows.isEmpty) return const <Chat>[];
    final byGuid = <String, Chat>{
      for (final state in chatStates.values)
        if (_registeredLogicalIdForChat(state.chat) != null) state.chat.guid: state.chat,
    };
    if (!kIsWeb) {
      final query = Database.chats.query(Chat_.originalROWID.oneOf(registeredRows.toList())).build();
      for (final chat in query.find()) {
        if (_registeredLogicalIdForChat(chat) != null) {
          byGuid.putIfAbsent(chat.guid, () => chat);
        }
      }
      query.close();
    }
    final chats = byGuid.values.toList(growable: false)
      ..sort((left, right) => left.originalROWID!.compareTo(right.originalROWID!));
    return chats;
  }

  List<Chat> _logicalCandidateChats() {
    final certificate = LogicalConversationViewPolicy.certificateForLogicalId(
      LogicalConversationId.certified(LogicalConversationViewPolicy.bankedLogicalConversationId),
    );
    if (certificate == null) return const <Chat>[];
    return _registeredLogicalChats()
        .where((chat) => certificate.containsSourceRowId(chat.originalROWID))
        .toList(growable: false);
  }

  LogicalConversationReadCertificate? get _logicalDefinition =>
      LogicalConversationViewPolicy.resolve(_logicalCandidateChats().map((chat) => chat.originalROWID));

  List<Chat> _logicalSourceChats(LogicalConversationReadCertificate definition) {
    final sources = _registeredLogicalChats()
        .where((chat) => definition.containsSourceRowId(chat.originalROWID))
        .map((chat) => findChatByGuid(chat.guid) ?? chat)
        .toList();
    sources.sort((a, b) => a.originalROWID!.compareTo(b.originalROWID!));
    return sources;
  }

  LogicalConversationRegistry get _logicalRegistry {
    final chats = _registeredLogicalChats();
    final bindings = <LogicalConversationPhysicalChatBinding>[
      for (final chat in chats)
        if (chat.originalROWID != null)
          LogicalConversationPhysicalChatBinding.fromProviderGuid(
            sourceChatRowId: chat.originalROWID!,
            sourceChatGuid: chat.guid,
          ),
    ];
    try {
      return LogicalConversationRegistryBinding.bindAuthorities(
        authorities: LogicalConversationViewPolicy.activeAuthorities,
        physicalChats: bindings,
      );
    } catch (_) {
      return LogicalConversationRegistry.empty();
    }
  }

  /// Immutable, fail-closed application registry for certified read identity.
  LogicalConversationRegistry get logicalConversationRegistry => _logicalRegistry;

  Map<String, String> _logicalRuntimeBindingSnapshot() {
    final snapshot = <String, String>{};
    for (final entry in _logicalRegistry.entries) {
      final certificate = LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
      if (certificate == null) continue;
      final material = <String>[
        'members:${entry.members.length}',
        ...entry.certifiedMemberRefs.map((ref) => 'certified:${ref.fingerprint}'),
        ...entry.runtimePhysicalRefs.map((ref) => 'available:${ref.fingerprint}'),
      ]..sort();
      snapshot[certificate.id] = sha256.convert(utf8.encode(jsonEncode(material))).toString();
    }
    return snapshot;
  }

  void _observeLogicalInventoryTransitions({required bool reportChanges}) {
    final changed = _logicalMembershipAvailability.observe(
      _logicalRuntimeBindingSnapshot(),
      reportChanges: reportChanges,
    );
    if (!GetIt.I.isRegistered<EventDispatcher>()) return;
    for (final logicalId in changed) {
      _resetLogicalProjectionCursors(logicalId);
      EventDispatcherSvc.emit(logicalMembershipAdvancedEvent, <String, dynamic>{'logicalId': logicalId});
    }
  }

  bool _matchesCertifiedProviderProof(Chat chat) {
    final rowId = chat.originalROWID;
    if (rowId == null || rowId <= 0 || chat.guid.isEmpty) return false;
    final arriving = LogicalConversationPhysicalChatBinding.fromProviderGuid(
      sourceChatRowId: rowId,
      sourceChatGuid: chat.guid,
    );
    return LogicalConversationViewPolicy.activeAuthorities.any(
      (authority) => authority.certificate.sourceChatGuidSha256.contains(arriving.sourceChatGuidSha256),
    );
  }

  LogicalConversationRegistryEntry? _registryEntryForChat(Chat chat) {
    final rowId = chat.originalROWID;
    if (rowId == null || _registeredLogicalIdForChat(chat) == null) return null;
    return _logicalRegistry.entryForRuntimeBinding(
      physicalRef: PhysicalConversationRef.fromStablePhysicalGuid(chat.guid),
      sourceChatRowId: rowId,
    );
  }

  LogicalConversationReadCertificate? _logicalDefinitionForChat(Chat chat) {
    final entry = _registryEntryForChat(chat);
    return entry == null ? null : LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
  }

  List<Chat> _logicalSourceChatsForEntry(LogicalConversationRegistryEntry entry) {
    final sources = _registeredLogicalChats()
        .where((chat) {
          final rowId = chat.originalROWID;
          return rowId != null &&
              entry.containsRuntimeBinding(
                physicalRef: PhysicalConversationRef.fromStablePhysicalGuid(chat.guid),
                sourceChatRowId: rowId,
              );
        })
        .map((chat) => findChatByGuid(chat.guid) ?? chat)
        .toList(growable: false);
    sources.sort((left, right) => left.originalROWID!.compareTo(right.originalROWID!));
    return sources;
  }

  Chat? _presentationChatForEntry(LogicalConversationRegistryEntry entry) {
    final sources = _logicalSourceChatsForEntry(entry);
    if (sources.isEmpty) return null;
    final orderedMembers = <LogicalConversationRegistryMember>[
      entry.presentationMember,
      ...entry.members.where((member) => !member.isPresentation),
    ];
    return orderedMembers
        .map((member) => sources.firstWhereOrNull((candidate) => candidate.originalROWID == member.sourceChatRowId))
        .firstWhereOrNull((source) => source != null);
  }

  Chat? _presentationChatForDefinition(LogicalConversationReadCertificate definition) {
    final entry = _logicalRegistry.entryForLogicalId(LogicalConversationId.certified(definition.id));
    return entry == null ? null : _presentationChatForEntry(entry);
  }

  /// True for either protected source ROWID even while the second source is
  /// absent. Write guards intentionally fail closed before projection activates.
  bool isApprovedLogicalSource(Chat chat) => _registeredLogicalIdForChat(chat) != null;

  LogicalCandidateQuarantineRecord? _logicalCandidateRecordForChat(Chat chat, {required int nowEpochMs}) {
    final record = _logicalCandidateQuarantine.recordFor(
      PhysicalConversationRef.fromStablePhysicalGuid(chat.guid),
      nowEpochMs: nowEpochMs,
    );
    _scheduleLogicalCandidateQuarantinePersistence(nowEpochMs);
    return record;
  }

  List<LogicalAddressEvidence> _logicalCandidateAddresses(Chat chat) {
    final handles = chat.handles.isNotEmpty ? chat.handles.toList() : chat.participants;
    return handles
        .map((handle) => LogicalAddressEvidence(address: handle.address, country: handle.country))
        .toList(growable: false);
  }

  LogicalCandidateContextMatch _logicalCandidateContextMatchForChat(Chat chat) {
    if (isApprovedLogicalSource(chat)) return const LogicalCandidateContextMatch.none();
    final service = _logicalChatService(chat.guid);
    if (service.isEmpty) return const LogicalCandidateContextMatch.none();
    return _logicalCandidateContexts
        .retainTargets(LogicalConversationViewPolicy.certificateLedgerLogicalIds)
        .matchCandidate(service: service, participants: _logicalCandidateAddresses(chat));
  }

  LogicalCandidateReconciliationContext? _currentLogicalCandidateContext(LogicalConversationId logicalId) {
    final context = _logicalCandidateContexts.contextFor(logicalId);
    final certificate = LogicalConversationViewPolicy.certificateForLogicalId(logicalId);
    return context != null && certificate != null && context.certificateRevision == certificate.revision
        ? context
        : null;
  }

  bool _matchesBuild99PotentialPredicate(Chat chat) {
    if (chat.style != 43) return false;
    final handles = chat.handles.isNotEmpty ? chat.handles.toList() : chat.participants;
    const generation = LogicalConversationOutboundRoutePolicy.comcastNodeUpdatesGeneration;
    return LogicalConversationOutboundRoutePolicy.canMatchCertifiedExternalParticipantSet(
      handles.map((handle) => LogicalAddressEvidence(address: handle.address, country: handle.country)),
      expectedExternalParticipantCount: generation.expectedExternalParticipantCount,
      expectedExternalParticipantSetSha256: generation.expectedExternalParticipantSetSha256,
    );
  }

  /// A nominated candidate remains protected from ordinary-chat mutation even
  /// after bounded quarantine expires. Visibility and mutation protection are
  /// separate: rejected/expired candidates become visible, but never silently
  /// fall back to ordinary-chat semantics.
  LogicalMutationProtection logicalMutationProtectionFor(Chat chat) {
    if (LogicalConversationViewPolicy.certificateLedgerCorrupt) {
      return classifyLogicalMutationProtection(
        authoritativeCertificateLedgerCorrupt: true,
        certifiedSource: false,
        quarantinedCandidate: false,
        bankedGenerationCandidate: false,
      );
    }

    final certified = isApprovedLogicalSource(chat);
    final quarantined =
        !certified && _logicalCandidateRecordForChat(chat, nowEpochMs: DateTime.now().millisecondsSinceEpoch) != null;

    final genericContextCandidate =
        !certified &&
        !quarantined &&
        _logicalCandidateContextMatchForChat(chat).kind != LogicalCandidateContextMatchKind.none;
    return classifyLogicalMutationProtection(
      authoritativeCertificateLedgerCorrupt: false,
      certifiedSource: certified,
      quarantinedCandidate: quarantined,
      bankedGenerationCandidate: genericContextCandidate || _matchesBuild99PotentialPredicate(chat),
    );
  }

  bool isPotentialLogicalSource(Chat chat) => logicalMutationProtectionFor(chat).isProtected;

  /// Read-only notification/presentation classification. Lookup materializes
  /// a bounded quarantine expiry through the existing durable state machine;
  /// it does not weaken candidate mutation protection.
  LogicalCandidateQuarantinePhase? logicalCandidateQuarantinePhaseFor(Chat chat) =>
      _logicalCandidateRecordForChat(chat, nowEpochMs: DateTime.now().millisecondsSinceEpoch)?.phase;

  /// Certified conversations may mutate their local logical settings ledger.
  /// Candidates and corrupt-authority state must not fall through to physical
  /// chat settings merely because no complete certificate is currently bound.
  bool canApplyConversationLocalStateMutation(Chat chat) =>
      !isPotentialLogicalSource(chat) || isApprovedLogicalSource(chat);

  bool _isLogicalCandidateTemporarilySuppressed(
    Chat chat,
    LogicalConversationRegistry registry, {
    required int nowEpochMs,
  }) {
    if (isApprovedLogicalSource(chat)) return false;
    final record = _logicalCandidateRecordForChat(chat, nowEpochMs: nowEpochMs);
    final contextMatch = _logicalCandidateContextMatchForChat(chat);
    final targetLogicalId =
        contextMatch.uniqueTarget ??
        (contextMatch.kind == LogicalCandidateContextMatchKind.none && _matchesBuild99PotentialPredicate(chat)
            ? LogicalConversationViewPolicy.bankedApplicationLogicalId
            : null);
    if (shouldSuppressFirstFramePotentialCandidate(
      hasCandidateRecord: record != null,
      // Ambiguous cross-conversation matches stay visible and read-only. They
      // are never hidden under an arbitrarily selected logical projection.
      provenPotentialPredicate: targetLogicalId != null,
      targetProjectionAvailable: targetLogicalId != null && registry.entryForLogicalId(targetLogicalId) != null,
    )) {
      return true;
    }
    return shouldTemporarilySuppressLogicalCandidate(
      record: record,
      nowEpochMs: nowEpochMs,
      targetProjectionAvailable: record != null && registry.entryForLogicalId(record.targetLogicalId) != null,
      admittedToActiveCertificate: false,
    );
  }

  Future<T> _withLogicalCandidateQuarantineLock<T>(Future<T> Function() operation) async {
    while (_logicalCandidateQuarantineMutex != null) {
      await _logicalCandidateQuarantineMutex!.future;
    }
    final mutex = Completer<void>();
    _logicalCandidateQuarantineMutex = mutex;
    try {
      return await operation();
    } finally {
      if (identical(_logicalCandidateQuarantineMutex, mutex)) _logicalCandidateQuarantineMutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }

  Future<void> _persistLogicalCandidateQuarantineUnlocked({required int nowEpochMs}) async {
    final fingerprint = _logicalCandidateQuarantine.stableFingerprintAt(nowEpochMs: nowEpochMs);
    if (fingerprint == _logicalCandidateQuarantinePersistedFingerprint) return;
    await PrefsSvc.messaging.saveLogicalCandidateQuarantineJson(
      jsonEncode(_logicalCandidateQuarantine.toJson(nowEpochMs: nowEpochMs)),
    );
    _logicalCandidateQuarantinePersistedFingerprint = fingerprint;
  }

  Future<void> _persistLogicalCandidateQuarantine({required int nowEpochMs}) =>
      _withLogicalCandidateQuarantineLock(() => _persistLogicalCandidateQuarantineUnlocked(nowEpochMs: nowEpochMs));

  Future<void> _reconcileDeferredLogicalNotifications() async {
    if (!GetIt.I.isRegistered<NotificationsService>()) return;
    try {
      await GetIt.I.isReady<NotificationsService>();
      await NotificationsSvc.reconcileDeferredLogicalNotifications();
    } catch (error, trace) {
      Logger.warn(
        'Deferred logical notifications remain pending after candidate transition',
        error: error,
        trace: trace,
        tag: 'LogicalCandidate',
      );
    }
  }

  void _publishLogicalCandidateTransitionSideEffects() {
    _scheduleListVersionUpdate(immediate: true);
    unawaited(updateShareTargets());
    unawaited(_reconcileDeferredLogicalNotifications());
  }

  void _scheduleLogicalCandidateQuarantinePersistence(int nowEpochMs) {
    final fingerprint = _logicalCandidateQuarantine.stableFingerprintAt(nowEpochMs: nowEpochMs);
    if (fingerprint == _logicalCandidateQuarantinePersistedFingerprint) return;
    unawaited(
      _persistLogicalCandidateQuarantine(
        nowEpochMs: nowEpochMs,
      ).then((_) => _publishLogicalCandidateTransitionSideEffects()).catchError((Object error, StackTrace trace) {
        Logger.warn(
          'Logical candidate visibility state could not be persisted',
          error: error,
          trace: trace,
          tag: 'LogicalCandidate',
        );
      }),
    );
  }

  Future<void> _restoreLogicalCandidateQuarantine() async {
    final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
    final raw = PrefsSvc.messaging.loadLogicalCandidateQuarantineJson();
    if (raw == null) {
      _logicalCandidateQuarantine = LogicalCandidateQuarantineLedger.empty();
      _logicalCandidateQuarantinePersistedFingerprint = _logicalCandidateQuarantine.stableFingerprintAt(
        nowEpochMs: nowEpochMs,
      );
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Invalid logical candidate quarantine envelope');
      final restored = LogicalCandidateQuarantineLedger.fromJson(
        decoded.cast<String, dynamic>(),
        nowEpochMs: nowEpochMs,
      );
      _logicalCandidateQuarantine = restored;
      final canonical = jsonEncode(restored.toJson(nowEpochMs: nowEpochMs));
      final fingerprint = restored.stableFingerprintAt(nowEpochMs: nowEpochMs);
      if (canonical != raw) {
        try {
          await PrefsSvc.messaging.saveLogicalCandidateQuarantineJson(canonical);
          _logicalCandidateQuarantinePersistedFingerprint = fingerprint;
        } catch (error, trace) {
          _logicalCandidateQuarantinePersistedFingerprint = null;
          Logger.warn(
            'Materialized logical candidate visibility could not be persisted',
            error: error,
            trace: trace,
            tag: 'LogicalCandidate',
          );
        }
      } else {
        _logicalCandidateQuarantinePersistedFingerprint = fingerprint;
      }
    } catch (error, trace) {
      Logger.warn(
        'Discarding invalid logical candidate quarantine; physical chats remain visible',
        error: error,
        trace: trace,
        tag: 'LogicalCandidate',
      );
      _logicalCandidateQuarantine = LogicalCandidateQuarantineLedger.empty();
      _logicalCandidateQuarantinePersistedFingerprint = null;
      _scheduleLogicalCandidateQuarantinePersistence(nowEpochMs);
    }
  }

  Future<void> _restoreLogicalCandidateContexts() async {
    final raw = PrefsSvc.messaging.loadLogicalCandidateReconciliationContextsJson();
    if (raw == null) {
      _logicalCandidateContexts = LogicalCandidateReconciliationContextLedger.empty();
      _logicalCandidateContextsPersistedRevision = _logicalCandidateContexts.revision;
      return;
    }
    try {
      final restored = LogicalCandidateReconciliationContextLedger.decode(
        raw,
      ).retainTargets(LogicalConversationViewPolicy.certificateLedgerLogicalIds);
      _logicalCandidateContexts = restored;
      _logicalCandidateContextsPersistedRevision = restored.revision;
      if (restored.encode() != raw) {
        await PrefsSvc.messaging.saveLogicalCandidateReconciliationContextsJson(restored.encode());
      }
    } catch (error, trace) {
      Logger.warn(
        'Invalid logical candidate contexts discarded; provider reconstruction required',
        error: error,
        trace: trace,
        tag: 'LogicalCandidate',
      );
      _logicalCandidateContexts = LogicalCandidateReconciliationContextLedger.empty();
      _logicalCandidateContextsPersistedRevision = null;
    }
  }

  Future<void> _persistLogicalCandidateContexts(LogicalCandidateReconciliationContextLedger ledger) async {
    if (ledger.revision == _logicalCandidateContextsPersistedRevision) {
      _logicalCandidateContexts = ledger;
      return;
    }
    final encoded = ledger.encode();
    LogicalCandidateReconciliationContextLedger.decode(encoded);
    await PrefsSvc.messaging.saveLogicalCandidateReconciliationContextsJson(encoded);
    _logicalCandidateContexts = ledger;
    _logicalCandidateContextsPersistedRevision = ledger.revision;
    _scheduleListVersionUpdate(immediate: true);
  }

  Future<LogicalCandidateTransition> _commitLogicalCandidateTransition(
    LogicalCandidateTransition Function(LogicalCandidateQuarantineLedger working) transition, {
    required int nowEpochMs,
  }) => _withLogicalCandidateQuarantineLock(() async {
    final working = LogicalCandidateQuarantineLedger.fromJson(
      _logicalCandidateQuarantine.toJson(nowEpochMs: nowEpochMs),
      nowEpochMs: nowEpochMs,
    );
    final result = transition(working);
    if (!result.changed) {
      await _persistLogicalCandidateQuarantineUnlocked(nowEpochMs: nowEpochMs);
      return result;
    }
    final encoded = jsonEncode(working.toJson(nowEpochMs: nowEpochMs));
    final fingerprint = working.stableFingerprintAt(nowEpochMs: nowEpochMs);
    await PrefsSvc.messaging.saveLogicalCandidateQuarantineJson(encoded);
    _logicalCandidateQuarantine = working;
    _logicalCandidateQuarantinePersistedFingerprint = fingerprint;
    _publishLogicalCandidateTransitionSideEffects();
    return result;
  });

  String _logicalCandidateFingerprint(String namespace, Iterable<String> components) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'schema': logicalCandidateQuarantineSchema,
            'namespace': namespace,
            'components': components.toList(growable: false),
          }),
        ),
      )
      .toString();

  bool isLogicalConversation(Chat chat) => isApprovedLogicalSource(chat);

  bool _isBuild99WriterConversation(Chat chat) {
    final certificate = _registeredCertificateForChat(chat);
    return certificate?.id == LogicalConversationViewPolicy.bankedLogicalConversationId &&
        _logicalDefinition?.containsSourceRowId(chat.originalROWID) == true;
  }

  /// Public capability boundary for every UI and transport caller. Certified
  /// read membership alone never grants access to the banked writer route.
  LogicalWriterCapability logicalWriterCapabilityFor(Chat chat) => classifyLogicalWriterCapability(
    isCertified: isApprovedLogicalSource(chat),
    hasBuild99WriterBinding: _isBuild99WriterConversation(chat),
  );

  bool hasBuild99WriterCapability(Chat chat) =>
      logicalWriterCapabilityFor(chat) == LogicalWriterCapability.build99Writer;

  LogicalAuthorityRevision? logicalWriterAuthorityRevisionFor(Chat chat) =>
      hasBuild99WriterCapability(chat) ? currentLogicalAuthorityRevision : null;

  String logicalProjectionAuthorityRevisionFor(Chat chat) {
    final revision = logicalWriterAuthorityRevisionFor(chat);
    if (revision != null) return revision.authorityRevision;
    return hasBuild99WriterCapability(chat)
        ? 'UNOBSERVED_BUILD99_WRITER_AUTHORITY'
        : 'CERTIFIED_READ_ONLY_NO_WRITER_AUTHORITY';
  }

  LogicalRouteRuntimeStatus logicalRouteRuntimeStatusFor(Chat chat) {
    if (hasBuild99WriterCapability(chat)) return logicalRouteRuntimeStatus.value;
    return LogicalRouteRuntimeStatus(
      stage: LogicalRouteRuntimeStage.routeNotProven,
      reason: isApprovedLogicalSource(chat)
          ? 'CERTIFIED_LOGICAL_WRITE_UNAVAILABLE'
          : 'NOT_A_CERTIFIED_LOGICAL_CONVERSATION',
    );
  }

  bool publishBuild99WriterBlocked(Chat chat, String reason) {
    if (!hasBuild99WriterCapability(chat)) return false;
    final revision = logicalWriterAuthorityRevisionFor(chat);
    logicalRouteRuntimeStatus.value = LogicalRouteRuntimeStatus(
      stage: LogicalRouteRuntimeStage.routeNotProven,
      reason: reason,
      certificateRevision: revision?.certificateRevision,
      authorityRevision: revision?.authorityRevision,
      authorityEpoch: revision?.epoch,
    );
    return true;
  }

  bool _canAffectBuild99WriterAuthority(Chat chat) {
    final certificate = _registeredCertificateForChat(chat);
    if (certificate != null) {
      return certificate.id == LogicalConversationViewPolicy.bankedLogicalConversationId;
    }
    final record = _logicalCandidateRecordForChat(chat, nowEpochMs: DateTime.now().millisecondsSinceEpoch);
    if (record != null) {
      return logicalCandidateTargets(record, LogicalConversationViewPolicy.bankedApplicationLogicalId);
    }
    final contextMatch = _logicalCandidateContextMatchForChat(chat);
    if (contextMatch.targets.contains(LogicalConversationViewPolicy.bankedApplicationLogicalId)) {
      return true;
    }
    if (chat.style != 43) return false;
    final handles = chat.handles.isNotEmpty ? chat.handles.toList() : chat.participants;
    const generation = LogicalConversationOutboundRoutePolicy.comcastNodeUpdatesGeneration;
    return LogicalConversationOutboundRoutePolicy.canMatchCertifiedExternalParticipantSet(
      handles.map((handle) => LogicalAddressEvidence(address: handle.address, country: handle.country)),
      expectedExternalParticipantCount: generation.expectedExternalParticipantCount,
      expectedExternalParticipantSetSha256: generation.expectedExternalParticipantSetSha256,
    );
  }

  String? logicalConversationIdFor(Chat chat) {
    final logicalId = _registeredLogicalIdForChat(chat);
    return logicalId == null ? null : LogicalConversationViewPolicy.authorityForLogicalId(logicalId)?.certificate.id;
  }

  /// Stable application identity for presentation, controller ownership,
  /// notifications and navigation. Physical GUIDs remain attached to source
  /// messages and provider mutations; they are never returned for a certified
  /// aggregate merely because one member is the current presentation row.
  LogicalConversationId conversationIdentityFor(Chat chat) {
    final certifiedId = _registeredLogicalIdForChat(chat);
    return certifiedId ?? LogicalConversationId.ordinarySingleton(chat.guid);
  }

  String conversationKeyFor(Chat chat) {
    final certifiedId = _registeredLogicalIdForChat(chat);
    return certifiedId?.value ?? chat.guid;
  }

  /// Compatibility resolver for legacy entry points that still carry a
  /// physical provider GUID. Unknown values are returned unchanged so ordinary
  /// chats preserve their historical identity.
  String conversationKeyForGuid(String guid) {
    final chat = findChatByGuid(guid);
    return chat == null ? guid : conversationKeyFor(chat);
  }

  /// Resolves both the new stable application key and the legacy physical
  /// GUID persisted by Build 99. The selected object is presentation-only;
  /// provider mutations still resolve exact source provenance independently.
  Chat? presentationChatForConversationKey(String key) {
    for (final chat in allChats) {
      if (conversationKeyFor(chat) == key || chat.guid == key) {
        return presentationChatFor(chat);
      }
    }
    try {
      final logicalId = LogicalConversationId.parse(key);
      final entry = _logicalRegistry.entryForLogicalId(logicalId);
      if (entry != null) {
        final presentation = _presentationChatForEntry(entry);
        if (presentation != null) return presentation;
      }
    } on FormatException {
      // Legacy physical GUID compatibility continues below.
    }
    if (!kIsWeb) {
      final legacyPhysical = Chat.findOne(guid: key);
      if (legacyPhysical != null) return presentationChatFor(legacyPhysical);
    }
    return null;
  }

  /// Revalidates the immutable notification envelope against current source
  /// membership. Logical envelopes never fall back to ordinary physical
  /// routing if their certificate is unavailable, stale, or revoked.
  NotificationConversationRoute? admitNotificationConversation({
    required String? conversationKey,
    required String? sourceChatGuid,
  }) {
    if (conversationKey == null || sourceChatGuid == null) return null;
    final source = findChatByGuid(sourceChatGuid) ?? (!kIsWeb ? Chat.findOne(guid: sourceChatGuid) : null);
    if (source == null) return null;

    final currentKey = conversationKeyFor(source);
    final presentation = presentationChatForConversationKey(conversationKey);
    final presentationMatches = presentation != null && conversationKeyFor(presentation) == conversationKey;
    final isLogical = isApprovedLogicalSource(source);
    final admitted = LogicalNotificationRoutePolicy.admits(
      admittedConversationKey: conversationKey,
      admittedSourceChatGuid: sourceChatGuid,
      currentSourceChatGuid: source.guid,
      currentConversationKey: currentKey,
      currentSourceIsCertified: isLogical,
      presentationResolvesToConversationKey: presentationMatches,
    );
    if (!admitted || presentation == null) return null;

    if (isLogical && !logicalSourceChatsFor(presentation).any((member) => member.guid == source.guid)) {
      return null;
    }
    return NotificationConversationRoute(source: source, presentation: presentation, isLogical: isLogical);
  }

  LogicalConversationSettings? logicalSettingsFor(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
    if (logicalId == null) return null;
    return _logicalSettings.forId(LogicalConversationId.certified(logicalId));
  }

  bool isConversationPinned(Chat chat) => logicalSettingsFor(chat)?.isPinned ?? (chat.isPinned ?? false);

  int? conversationPinIndex(Chat chat) => logicalSettingsFor(chat)?.pinIndex ?? chat.pinIndex;

  bool isConversationArchived(Chat chat) => logicalSettingsFor(chat)?.isArchived ?? (chat.isArchived ?? false);

  bool isConversationMuted(Chat chat) => logicalSettingsFor(chat)?.isMuted ?? chat.muteType == 'mute';

  LogicalUnreadConversationState? _logicalUnreadStateFor(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
    return logicalId == null ? null : _logicalUnreadStates.stateFor(LogicalConversationId.certified(logicalId));
  }

  /// Returns the retained exact-source ledger used by runtime read routing.
  /// Diagnostics receive a defensive copy and cannot mutate source truth.
  LogicalUnreadLedger? logicalUnreadLedgerFor(Chat chat) {
    final entry = _registryEntryForChat(chat);
    if (entry == null) return null;
    final sources = _logicalSourceChatsForEntry(entry);
    final synchronized = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
    final state = synchronized ?? _logicalUnreadStates.stateFor(entry.logicalId);
    return state == null ? null : LogicalUnreadLedger.fromJson(state.ledger.toJson());
  }

  LogicalMarkReadOutcome? logicalMarkReadOutcomeFor(Chat chat) => _logicalUnreadStateFor(chat)?.lastOutcome;

  bool logicalReadSyncPendingFor(Chat chat) {
    final entry = _registryEntryForChat(chat);
    final partiallyBound = entry != null && entry.runtimePhysicalRefs.length != entry.members.length;
    return partiallyBound || (_logicalUnreadStateFor(chat)?.syncPending ?? false);
  }

  void _refreshLogicalUnreadCompatibility({LogicalUnreadConversationState? latest}) {
    if (latest?.lastOutcome != null) {
      logicalMarkReadOutcome.value = latest!.lastOutcome;
    }
    logicalReadSyncPending.value = _logicalUnreadStates.anySyncPending;
  }

  /// Captures an immutable snapshot at mutation time and persists snapshots in
  /// FIFO order for each logical conversation. Dart's main isolate makes each
  /// in-memory ledger mutation synchronous; this queue closes the asynchronous
  /// SharedPreferences completion race without blocking unrelated conversations.
  Future<void> _persistLogicalUnreadState(LogicalUnreadConversationState state) {
    final logicalId = state.logicalId.value;
    final ledgerJson = jsonEncode(state.ledger.toJson());
    final syncPending = state.syncPending;
    return _logicalUnreadPersistence.run<void>(logicalId, () async {
      if (!identical(_logicalUnreadStates.stateFor(state.logicalId), state)) return;
      await PrefsSvc.messaging.saveLogicalUnreadLedgerJson(logicalId, ledgerJson);
      await PrefsSvc.messaging.saveLogicalReadSyncPending(logicalId, syncPending);
    });
  }

  void _scheduleLogicalUnreadPersistence(LogicalUnreadConversationState state) {
    unawaited(
      _persistLogicalUnreadState(state).catchError((Object error, StackTrace trace) {
        Logger.warn('Logical unread snapshot persistence failed', error: error, trace: trace, tag: 'LogicalUnread');
      }),
    );
  }

  bool isConversationUnread(Chat chat) {
    if (!isApprovedLogicalSource(chat)) {
      return getChatState(chat.guid)?.hasUnreadMessage.value ?? (chat.hasUnreadMessage ?? false);
    }
    final sources = logicalSourceChatsFor(chat);
    final logicalIdValue = logicalConversationIdFor(chat);
    if (logicalIdValue == null) return sources.any((source) => source.hasUnreadMessage == true);
    final logicalId = LogicalConversationId.certified(logicalIdValue);
    final synchronized = _synchronizeLogicalUnreadState(logicalId: logicalId, sourceSnapshot: sources);
    final cached = synchronized ?? _logicalUnreadStates.stateFor(logicalId);
    return (cached?.ledger.hasUnread ?? false) || sources.any((source) => source.hasUnreadMessage == true);
  }

  Future<void> toggleConversationUnreadFromUi(Chat chat, {bool force = false}) async {
    final isUnread = isConversationUnread(chat);
    if (isApprovedLogicalSource(chat)) {
      if (!isUnread) {
        showToast('Marking a certified conversation unread is unavailable.');
        return;
      }
      final decision = await markLogicalConversationRead(chat);
      if (!decision.isQualified) showToast('Failed to mark the certified conversation read.');
      return;
    }
    if (isPotentialLogicalSource(chat)) {
      showToast('Conversation state change unavailable while identity is being verified.');
      return;
    }
    final state = getChatState(chat.guid);
    if (state != null) {
      await setChatHasUnread(state.chat, !isUnread, force: force);
    } else {
      await chat.toggleHasUnreadAsync(!isUnread, force: force);
    }
  }

  bool shouldMuteConversationNotification(Chat chat, Message? message) {
    final logical = logicalSettingsFor(chat);
    if (logical == null) return chat.shouldMuteNotification(message);
    if (shouldPreserveSpecializedPhysicalMute(chat.muteType)) return chat.shouldMuteNotification(message);
    return shouldMuteLogicalConversationNotification(
      logicalAllMuted: logical.isMuted,
      unknownSenderFiltered:
          SettingsSvc.settings.filterUnknownSenders.value &&
          chat.handles.length == 1 &&
          chat.handles.first.contactsV2.isEmpty,
      globalTextDetection: SettingsSvc.settings.globalTextDetection.value,
      messageText: message?.text,
      notifyReactions: SettingsSvc.settings.notifyReactions.value,
      isReaction: ReactionTypes.toList().contains(message?.associatedMessageType ?? ''),
    );
  }

  bool isConversationInCustomGroup(Chat chat, int groupId) {
    final logical = logicalSettingsFor(chat);
    if (logical != null) return logical.customGroupIds.contains(groupId);
    return CustomGroupsSvc.groups.any(
      (group) => group.id == groupId && group.chats.any((member) => member.guid == chat.guid),
    );
  }

  List<Chat> chatsForCustomGroup(int groupId) =>
      allChats.where((chat) => isConversationInCustomGroup(chat, groupId)).toList();

  Future<bool> _mutateLogicalSettings(
    Chat chat, {
    required String kind,
    required Object? value,
    bool? isPinned,
    int? pinIndex,
    bool clearPinIndex = false,
    bool? isArchived,
    bool? isMuted,
    Set<int>? customGroupIds,
    int? customGroupDeltaId,
    bool? customGroupDeltaIncluded,
  }) => _logicalSettingsTransactions.run(() async {
    final certifiedId = logicalConversationIdFor(chat);
    if (certifiedId == null || _logicalSettings.isCorrupt) return false;
    final logicalId = LogicalConversationId.certified(certifiedId);
    var resolvedCustomGroupIds = customGroupIds;
    var resolvedValue = value;
    if (customGroupDeltaId != null && customGroupDeltaIncluded != null) {
      resolvedCustomGroupIds = applyLogicalCustomGroupDelta(
        current: _logicalSettings.forId(logicalId)?.customGroupIds ?? const <int>{},
        groupId: customGroupDeltaId,
        included: customGroupDeltaIncluded,
      );
      resolvedValue = resolvedCustomGroupIds.toList()..sort();
    }
    final revision = _logicalSettings.forId(logicalId)?.revision ?? 0;
    final operationId = _logicalSettings.operationId(
      logicalId: logicalId,
      expectedRevision: revision,
      kind: kind,
      value: resolvedValue,
    );
    final transaction = await commitLogicalConversationSettingsMutation(
      current: _logicalSettings,
      logicalId: logicalId,
      mutation: LogicalConversationSettingsMutation(
        operationId: operationId,
        expectedRevision: revision,
        isPinned: isPinned,
        pinIndex: pinIndex,
        clearPinIndex: clearPinIndex,
        isArchived: isArchived,
        isMuted: isMuted,
        customGroupIds: resolvedCustomGroupIds,
      ),
      persist: PrefsSvc.messaging.saveLogicalConversationSettingsJson,
    );
    if (!transaction.committed) {
      if (transaction.failure != null) {
        Logger.warn(
          'Logical conversation settings persistence failed; mutation was not published',
          error: transaction.failure,
          trace: transaction.failureTrace,
          tag: 'LogicalConversationSettings',
        );
      }
      return false;
    }
    if (transaction.applyResult.applied) _logicalSettings = transaction.ledger;
    final presentation = presentationChatFor(chat);
    _repositionChat(presentation, immediate: true);
    _scheduleListVersionUpdate(immediate: true);
    return true;
  });

  Future<void> setConversationCustomGroupMembership(Chat chat, int groupId, bool included) async {
    if (!isApprovedLogicalSource(chat)) return;
    await _mutateLogicalSettings(
      chat,
      kind: 'custom-groups',
      value: <String, Object>{'group': groupId, 'included': included},
      customGroupDeltaId: groupId,
      customGroupDeltaIncluded: included,
    );
  }

  Future<void> _restoreLogicalSettings() async {
    _logicalSettings = LogicalConversationSettingsLedger.decode(
      PrefsSvc.messaging.loadLogicalConversationSettingsJson(),
    );
    if (_logicalSettings.isCorrupt) return;
    final migrations = <LogicalConversationSettings>[];
    for (final entry in _logicalRegistry.entries) {
      final definition = LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
      if (definition == null) continue;
      final presentation = exactLogicalSettingsMigrationPresentation(
        _logicalSourceChats(definition),
        presentationSourceRowId: definition.presentationSourceChatRowId,
        sourceRowIdOf: (source) => source.originalROWID,
      );
      if (presentation == null) continue;
      migrations.add(
        LogicalConversationSettings(
          logicalId: entry.logicalId,
          isPinned: presentation.isPinned ?? false,
          pinIndex: presentation.isPinned == true ? presentation.pinIndex : null,
          isArchived: presentation.isArchived ?? false,
          isMuted: migrateLogicalAllMuteFromPhysicalProvenance(presentation.muteType),
          customGroupIds: presentation.customGroups.map((group) => group.id).whereType<int>().toSet(),
          migratedFromPhysicalProvenance: true,
        ),
      );
    }
    final transaction = await commitLogicalConversationSettingsMigrations(
      current: _logicalSettings,
      migrations: migrations,
      persist: PrefsSvc.messaging.saveLogicalConversationSettingsJson,
    );
    if (!transaction.committed) {
      if (transaction.failure != null) {
        Logger.warn(
          'Logical conversation settings migration persistence failed; physical provenance was not published',
          error: transaction.failure,
          trace: transaction.failureTrace,
          tag: 'LogicalConversationSettings',
        );
      }
      return;
    }
    if (transaction.changed) _logicalSettings = transaction.ledger;
  }

  List<Chat> logicalSourceChatsFor(Chat chat) {
    final entry = _registryEntryForChat(chat);
    if (entry == null) return <Chat>[chat];
    final sources = _logicalSourceChatsForEntry(entry);
    return sources.isEmpty ? <Chat>[chat] : sources;
  }

  /// Advances reconstructible pagination metadata whenever a source event is
  /// observed outside the hydration fetch itself. Any existing source cursor
  /// must re-establish its provider boundary before it can fetch another page.
  ///
  /// Only Sean's own execution (a from-me message or its provider update) can
  /// move the execution frontier. Other participants' messages, reactions and
  /// read activity can at most corroborate an existing execution, so they never
  /// invalidate a qualified authority; they only drop the cached snapshot.
  void noteLogicalSourceEvent(
    String physicalChatGuid, {
    bool authorityRelevant = true,
    bool unreadRelevant = false,
    int? unreadEventWatermark,
  }) {
    final source =
        findChatByGuid(physicalChatGuid) ??
        _registeredLogicalChats().firstWhereOrNull((candidate) => candidate.guid == physicalChatGuid);
    final entry = source == null ? null : _registryEntryForChat(source);
    final definition = entry == null ? null : LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
    if (source == null || entry == null || definition == null) return;
    _logicalSourceEventWatermarks.update(physicalChatGuid, (value) => value + 1, ifAbsent: () => 1);

    if (unreadRelevant) {
      final sources = _logicalSourceChats(definition);
      final state = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
      if (state != null) {
        final ref = _certifiedLogicalRefForSource(entry, source);
        if (ref != null) {
          final result = state.observeUnreadEvent(source: ref, observedWatermark: unreadEventWatermark);
          if (result == LogicalUnreadObservationResult.advanced) {
            _scheduleLogicalUnreadPersistence(state);
            _refreshLogicalUnreadCompatibility(latest: state);
          }
        }
      }
    }

    // Build 99's execution authority remains scoped to its banked logical ID.
    // Read-side events for another certified conversation cannot invalidate it.
    if (definition.id != LogicalConversationViewPolicy.bankedLogicalConversationId) return;
    if (authorityRelevant) {
      _invalidateBuild99LogicalAuthority('LOGICAL_SOURCE_EXECUTION_EVENT_OBSERVED');
      return;
    }
    _logicalRouteEvidence = null;
    _logicalRouteEvidenceAt = null;
    if (!logicalRouteRuntimeStatus.value.isQualified) {
      _scheduleLogicalAuthorityRecheck();
    }
  }

  Chat presentationChatFor(Chat chat) {
    final entry = _registryEntryForChat(chat);
    return entry == null ? chat : (_presentationChatForEntry(entry) ?? chat);
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

  List<LogicalAddressEvidence>? _logicalProviderParticipants(Map<String, dynamic> chat) {
    final rawParticipants = chat['participants'];
    if (rawParticipants is! List) return null;
    final participants = <LogicalAddressEvidence>[];
    for (final raw in rawParticipants) {
      if (raw is! Map) return null;
      final address = raw['address'];
      final country = raw['country'];
      if (address is! String || address.isEmpty || (country != null && country is! String)) return null;
      participants.add(LogicalAddressEvidence(address: address, country: country as String?));
    }
    return participants;
  }

  LogicalCandidateReconciliationContextLedger? _deriveLogicalCandidateContexts({
    required List<Map<String, dynamic>> scope,
    required List<LogicalAddressEvidence> vettedAliases,
    required String providerAccountFingerprint,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(providerAccountFingerprint)) return null;
    final contexts = <LogicalCandidateReconciliationContext>[];
    for (final certificate in LogicalConversationViewPolicy.activeCertificates) {
      final sources = <LogicalCandidateContextSource>[];
      final orderedMembers = certificate.members.toList(growable: false)
        ..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
      for (final member in orderedMembers) {
        final matches = scope
            .where((chat) {
              final rowId = (chat['originalROWID'] as num?)?.toInt();
              final guid = chat['guid']?.toString() ?? '';
              return rowId == member.sourceChatRowId &&
                  guid.isNotEmpty &&
                  LogicalConversationRegistryBinding.sourceMatchesCertificate(
                    certificate,
                    sourceChatRowId: rowId,
                    providerGuid: guid,
                  );
            })
            .toList(growable: false);
        if (matches.length != 1) return null;
        final guid = matches.single['guid']!.toString();
        final service = _logicalChatService(guid);
        final participants = _logicalProviderParticipants(matches.single);
        if (service.isEmpty || participants == null) return null;
        sources.add(LogicalCandidateContextSource(service: service, participants: participants));
      }
      final context = LogicalCandidateReconciliationContext.derive(
        targetLogicalId: LogicalConversationId.certified(certificate.id),
        certificateRevision: certificate.revision,
        certifiedSources: sources,
        vettedAliases: vettedAliases,
        providerAccountFingerprint: providerAccountFingerprint,
      );
      if (context == null) return null;
      contexts.add(context);
    }
    final activeIds = contexts.map((context) => context.targetLogicalId).toSet();
    for (final existing in _logicalCandidateContexts.contexts) {
      if (LogicalConversationViewPolicy.certificateLedgerLogicalIds.contains(existing.targetLogicalId) &&
          !activeIds.contains(existing.targetLogicalId)) {
        contexts.add(existing);
      }
    }
    return LogicalCandidateReconciliationContextLedger(contexts);
  }

  Future<List<LogicalRouteCandidateEvidence>?> _collectGenericCertifiedReadEvidence(
    LogicalConversationReadCertificate definition,
    List<Map<String, dynamic>> scope,
  ) async {
    final evidence = <LogicalRouteCandidateEvidence>[];
    final members = definition.members.toList(growable: false)
      ..sort((left, right) => left.sourceChatRowId.compareTo(right.sourceChatRowId));
    for (final member in members) {
      final scoped = scope
          .where((chat) {
            final rowId = (chat['originalROWID'] as num?)?.toInt();
            final guid = chat['guid']?.toString() ?? '';
            return rowId == member.sourceChatRowId &&
                guid.isNotEmpty &&
                LogicalConversationRegistryBinding.sourceMatchesCertificate(
                  definition,
                  sourceChatRowId: rowId,
                  providerGuid: guid,
                );
          })
          .toList(growable: false);
      if (scoped.length != 1) return null;
      final guid = scoped.single['guid']!.toString();
      final responses = await Future.wait(<Future<dynamic>>[
        HttpSvc.chat.fetchOne(guid, withQuery: 'participants'),
        HttpSvc.chat.fetchOne(guid, withQuery: 'participants'),
      ]);
      final firstRaw = responses.first.data?['data'];
      final secondRaw = responses.last.data?['data'];
      if (firstRaw is! Map || secondRaw is! Map) return null;
      final first = Map<String, dynamic>.from(firstRaw.cast<String, dynamic>());
      final second = Map<String, dynamic>.from(secondRaw.cast<String, dynamic>());
      final participants = _logicalProviderParticipants(first);
      final snapshot = await _collectLogicalRouteMessageSnapshot(guid);
      final properties = _logicalChatGenerationProperties(first);
      final verificationProperties = _logicalChatGenerationProperties(second);
      final identityStable =
          snapshot.complete &&
          participants != null &&
          (first['originalROWID'] as num?)?.toInt() == member.sourceChatRowId &&
          first['guid']?.toString() == guid &&
          second['guid']?.toString() == guid &&
          first['groupId']?.toString() == scoped.single['groupId']?.toString() &&
          properties.complete &&
          verificationProperties.complete &&
          _logicalChatRouteFingerprint(first) == _logicalChatRouteFingerprint(second);
      if (!identityStable) return null;

      final messages = <LogicalRouteMessageEvidence>[];
      for (final raw in snapshot.messages) {
        final rowId = (raw['originalROWID'] as num?)?.toInt();
        final messageGuid = raw['guid']?.toString();
        final createdAt = (raw['dateCreated'] as num?)?.toInt();
        final error = (raw['error'] as num?)?.toInt();
        final itemType = (raw['itemType'] as num?)?.toInt();
        final isFromMe = raw['isFromMe'];
        if (rowId == null ||
            rowId <= 0 ||
            messageGuid == null ||
            messageGuid.isEmpty ||
            createdAt == null ||
            createdAt <= 0 ||
            error == null ||
            itemType == null ||
            isFromMe is! bool) {
          return null;
        }
        messages.add(
          LogicalRouteMessageEvidence(
            messageGuid: messageGuid,
            messageRowId: rowId,
            createdAtEpoch: createdAt,
            isFromMe: isFromMe,
            error: error,
            itemType: itemType,
            associatedMessageGuid: raw['associatedMessageGuid']?.toString(),
            replyToGuid:
                raw['threadOriginatorGuid']?.toString() ??
                raw['threadOriginatorGUID']?.toString() ??
                raw['replyToGuid']?.toString(),
            account: raw['account']?.toString() ?? '',
          ),
        );
      }
      evidence.add(
        LogicalRouteCandidateEvidence(
          sourceChatRowId: member.sourceChatRowId,
          sourceChatGuid: guid,
          sourceService: _logicalChatService(guid),
          sourceAccount: '',
          chatIdentifier: first['chatIdentifier']?.toString() ?? '',
          style: (first['style'] as num?)?.toInt() ?? -1,
          lastAddressedHandle: LogicalAddressEvidence(address: first['lastAddressedHandle']?.toString() ?? ''),
          participants: participants,
          chatSnapshotComplete: true,
          messageSnapshotComplete: true,
          lastKnownHybridState: properties.lastKnownHybridState,
          shouldForceToSms: properties.shouldForceToSms,
          lastSeenMessageGuid: properties.lastSeenMessageGuid,
          groupPhotoGuid: properties.groupPhotoGuid,
          groupIdentifier: first['groupId']?.toString(),
          messages: messages,
          successfulOutbounds: const <LogicalSuccessfulOutboundEvidence>[],
        ),
      );
    }
    return evidence;
  }

  void _scheduleLogicalCandidateReconciliation({Duration delay = const Duration(seconds: 2)}) {
    _logicalCandidateReconciliationTimer?.cancel();
    _logicalCandidateReconciliationTimer = Timer(delay, () {
      unawaited(_reconcileLogicalCandidatesAcrossRegistry());
    });
  }

  Future<void> _reconcileLogicalCandidatesAcrossRegistry() async {
    if (_logicalCandidateReconciliationMutex != null || LogicalConversationViewPolicy.activeCertificates.isEmpty) {
      return;
    }
    final mutex = Completer<void>();
    final generation = _logicalCandidateReconciliationGeneration;
    _logicalCandidateReconciliationMutex = mutex;
    try {
      final accountBefore = _logicalAccountProjection((await HttpSvc.icloud.getAccountInfo()).data['data']);
      final scopeBefore = await _collectLogicalRouteChatScope();
      final scopeAfter = await _collectLogicalRouteChatScope();
      final accountAfter = _logicalAccountProjection((await HttpSvc.icloud.getAccountInfo()).data['data']);
      if (!scopeBefore.complete ||
          !scopeAfter.complete ||
          scopeBefore.fingerprint != scopeAfter.fingerprint ||
          accountBefore.fingerprint.isEmpty ||
          accountBefore.fingerprint != accountAfter.fingerprint) {
        return;
      }
      final aliases = accountAfter.vettedAliases
          .map((alias) => LogicalAddressEvidence(address: alias))
          .toList(growable: false);
      final contexts = _deriveLogicalCandidateContexts(
        scope: scopeAfter.chats,
        vettedAliases: aliases,
        providerAccountFingerprint: accountAfter.fingerprint,
      );
      if (contexts == null || generation != _logicalCandidateReconciliationGeneration) return;
      await _persistLogicalCandidateContexts(contexts);

      final certifiedRows = LogicalConversationViewPolicy.approvedSourceRowIds;
      final candidatesByTarget = <LogicalConversationId, Map<int, String>>{};
      for (final chat in scopeAfter.chats) {
        final rowId = (chat['originalROWID'] as num?)?.toInt();
        final guid = chat['guid']?.toString() ?? '';
        final service = _logicalChatService(guid);
        final participants = _logicalProviderParticipants(chat);
        if (rowId == null || rowId <= 0 || certifiedRows.contains(rowId) || service.isEmpty || participants == null) {
          continue;
        }
        final match = contexts.matchCandidate(service: service, participants: participants);
        final target = match.uniqueTarget;
        if (target == null || _currentLogicalCandidateContext(target) == null) continue;
        candidatesByTarget.putIfAbsent(target, () => <int, String>{})[rowId] = guid;
      }

      final orderedTargets = candidatesByTarget.keys.toList(growable: false)..sort();
      for (final target in orderedTargets) {
        if (generation != _logicalCandidateReconciliationGeneration) return;
        final definition = LogicalConversationViewPolicy.certificateForLogicalId(target);
        final context = _currentLogicalCandidateContext(target);
        if (definition == null || context == null || context.providerAccountFingerprint != accountAfter.fingerprint) {
          continue;
        }
        final certifiedEvidence = await _collectGenericCertifiedReadEvidence(definition, scopeAfter.chats);
        if (certifiedEvidence == null || certifiedEvidence.isEmpty) continue;
        await _advanceLogicalReadCertificate(
          definition,
          scopeAfter.chats,
          certifiedEvidence,
          candidatesByTarget[target]!,
          aliases,
          accountContextFingerprint: accountAfter.fingerprint,
        );
      }
    } catch (error, trace) {
      Logger.warn(
        'Generic logical candidate reconciliation remains pending',
        error: error,
        trace: trace,
        tag: 'LogicalCandidate',
      );
    } finally {
      if (identical(_logicalCandidateReconciliationMutex, mutex)) _logicalCandidateReconciliationMutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
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
    const generation = LogicalConversationOutboundRoutePolicy.comcastNodeUpdatesGeneration;
    final authoritativeAccountSnapshotStable =
        accountBefore.fingerprint.isNotEmpty &&
        accountBefore.fingerprint == accountAfter.fingerprint &&
        accountBefore.fingerprint == generation.expectedAccountSnapshotSha256;

    final candidates = <LogicalRouteCandidateEvidence>[];
    for (var index = 0; index < sources.length; index++) {
      final chatData = Map<String, dynamic>.from((responses[1 + index].data['data'] as Map).cast<String, dynamic>());
      final verificationChatData = Map<String, dynamic>.from(
        (chatVerificationResponses[index].data['data'] as Map).cast<String, dynamic>(),
      );
      final snapshot = snapshots[index];
      final rawMessages = snapshot.messages;
      final sourceChatGuid = chatData['guid']?.toString() ?? '';
      final sourceService = _logicalChatService(sourceChatGuid);
      final authoritativeAccount = LogicalConversationOutboundRoutePolicy.authoritativeAccountFactFor(
        certificate: generation,
        sourceChatGuid: sourceChatGuid,
        service: sourceService,
      );
      final authoritativeAccountFallbackAvailable = authoritativeAccountSnapshotStable && authoritativeAccount != null;
      final successfulOutbounds = <LogicalSuccessfulOutboundEvidence>[];
      final messages = <LogicalRouteMessageEvidence>[];
      var sawAccountFactPresentAndMatching = false;
      var sawAccountFactContradiction = false;
      final observedAccountBindings = <String>{};
      for (final message in rawMessages) {
        final rowId = (message['originalROWID'] as num?)?.toInt();
        final guid = message['guid']?.toString();
        final createdAt = (message['dateCreated'] as num?)?.toInt();
        final error = (message['error'] as num?)?.toInt();
        final itemType = (message['itemType'] as num?)?.toInt();
        final isFromMe = message['isFromMe'];
        final associatedMessageGuid = message['associatedMessageGuid']?.toString();
        final replyToGuid =
            message['threadOriginatorGuid']?.toString() ??
            message['threadOriginatorGUID']?.toString() ??
            message['replyToGuid']?.toString();
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
        final accountFact = LogicalConversationOutboundRoutePolicy.resolveAccountFact(
          providerFieldPresent: message.containsKey('account'),
          providerValue: message['account'],
          expectedAccountSha256: authoritativeAccount?.accountSha256 ?? '',
          authoritativeFallbackAvailable: authoritativeAccountFallbackAvailable,
        );
        sawAccountFactPresentAndMatching |= accountFact.state == LogicalProviderFactState.presentAndMatches;
        sawAccountFactContradiction |= accountFact.state == LogicalProviderFactState.presentAndContradicts;
        final providerAccountValue = message['account'];
        final account = accountFact.invariantSatisfied
            ? authoritativeAccount?.accountSha256 ??
                  (providerAccountValue is String && providerAccountValue.isNotEmpty
                      ? LogicalConversationOutboundRoutePolicy.providerValueFingerprint(providerAccountValue)
                      : '')
            : '';
        if (account.isNotEmpty) observedAccountBindings.add(account);
        messages.add(
          LogicalRouteMessageEvidence(
            messageGuid: guid,
            messageRowId: rowId,
            createdAtEpoch: createdAt,
            isFromMe: isFromMe,
            error: error,
            itemType: itemType,
            associatedMessageGuid: associatedMessageGuid,
            replyToGuid: replyToGuid,
            account: account,
            accountFact: accountFact,
          ),
        );
        if (message['isFromMe'] == true &&
            error == 0 &&
            itemType == 0 &&
            (associatedMessageGuid == null || associatedMessageGuid.isEmpty)) {
          final authoritativeTerminal = account.isEmpty
              ? null
              : LogicalConversationOutboundRoutePolicy.authoritativeTerminalFactFor(
                  certificate: generation,
                  sourceChatGuid: sourceChatGuid,
                  service: sourceService,
                  accountSha256: account,
                  messageGuid: guid,
                  messageRowId: rowId,
                );
          final isSentFact = LogicalConversationOutboundRoutePolicy.resolveTerminalFact(
            providerFieldPresent: message.containsKey('isSent'),
            providerValue: message['isSent'],
            authoritativeFallbackValue: authoritativeAccountSnapshotStable && authoritativeTerminal?.isSent == true,
          );
          final isFinishedFact = LogicalConversationOutboundRoutePolicy.resolveTerminalFact(
            providerFieldPresent: message.containsKey('isFinished'),
            providerValue: message['isFinished'],
            authoritativeFallbackValue: authoritativeAccountSnapshotStable && authoritativeTerminal?.isFinished == true,
          );
          successfulOutbounds.add(
            LogicalSuccessfulOutboundEvidence(
              messageGuid: guid,
              messageRowId: rowId,
              createdAtEpoch: createdAt,
              terminalAcknowledgement: isSentFact.invariantSatisfied && isFinishedFact.invariantSatisfied,
              account: account,
              accountFact: accountFact,
              isSentFact: isSentFact,
              isFinishedFact: isFinishedFact,
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
      sawAccountFactContradiction |= observedAccountBindings.length > 1;
      final sourceAccountFact = sawAccountFactContradiction
          ? const LogicalProviderFactEvidence(state: LogicalProviderFactState.presentAndContradicts)
          : sawAccountFactPresentAndMatching
          ? const LogicalProviderFactEvidence(state: LogicalProviderFactState.presentAndMatches)
          : LogicalProviderFactEvidence(
              state: LogicalProviderFactState.unavailable,
              satisfiedByAuthoritativeFallback: authoritativeAccountFallbackAvailable,
            );
      candidates.add(
        LogicalRouteCandidateEvidence(
          sourceChatRowId: (chatData['originalROWID'] as num?)?.toInt() ?? -1,
          sourceChatGuid: sourceChatGuid,
          sourceService: sourceService,
          sourceAccount: sourceAccountFact.invariantSatisfied
              ? observedAccountBindings.singleOrNull ?? authoritativeAccount?.accountSha256 ?? ''
              : '',
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
          groupIdentifier: chatData['groupId']?.toString(),
          messages: messages,
          successfulOutbounds: successfulOutbounds,
          sourceAccountFact: sourceAccountFact,
        ),
      );
    }

    final candidateScopeSnapshotComplete =
        candidateScopeBefore.complete &&
        candidateScopeAfter.complete &&
        candidateScopeBefore.fingerprint == candidateScopeAfter.fingerprint;
    final candidateAccountContextFingerprint =
        accountBefore.fingerprint.isNotEmpty && accountBefore.fingerprint == accountAfter.fingerprint
        ? accountBefore.fingerprint
        : '';
    final unadmittedPotentialSources = candidateScopeSnapshotComplete
        ? _logicalUnadmittedPotentialSources(
            candidateScopeAfter.chats,
            candidates,
            accountBefore.vettedAliases.map((alias) => LogicalAddressEvidence(address: alias)).toList(),
          )
        : const <int, String>{};
    if (unadmittedPotentialSources.isNotEmpty &&
        await _advanceLogicalReadCertificate(
          definition,
          candidateScopeAfter.chats,
          candidates,
          unadmittedPotentialSources,
          accountBefore.vettedAliases.map((alias) => LogicalAddressEvidence(address: alias)).toList(),
          accountContextFingerprint: candidateAccountContextFingerprint,
        )) {
      return _collectLogicalRouteEvidence(chat);
    }

    return LogicalRouteEvidence(
      logicalId: definition.id,
      certificateId: '$logicalConversationOutboundRouteSchema:${definition.id}',
      certifiedSourceChatGuids: {
        for (final source in sources)
          if (source.originalROWID != null &&
              LogicalConversationViewPolicy.sourceGuidMatchesActiveProof(source.originalROWID!, source.guid))
            source.originalROWID!: source.guid,
      },
      backendComputerId: serverSnapshotStable ? serverBefore.computerId : '',
      detectedIMessage: serverSnapshotStable && serverBefore.detectedIMessage,
      privateApiConnected: serverSnapshotStable && serverBefore.privateApiConnected,
      helperConnected: serverSnapshotStable && serverBefore.helperConnected,
      accountSnapshotBeforeSha256: accountBefore.fingerprint,
      accountSnapshotAfterSha256: accountAfter.fingerprint,
      activeSelfAlias: LogicalAddressEvidence(address: accountBefore.activeAlias),
      vettedSelfAliases: accountBefore.vettedAliases.map((alias) => LogicalAddressEvidence(address: alias)).toList(),
      executionGenerationCertificate: generation,
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
        (rawLastSeen == null || rawLastSeen is String) &&
        (rawGroupPhoto == null || rawGroupPhoto is String);
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
      'groupId': chatData['groupId']?.toString(),
      'style': (chatData['style'] as num?)?.toInt(),
      'lastAddressedHandle': chatData['lastAddressedHandle']?.toString(),
      'participants': participants,
      'propertiesComplete': properties.complete,
      'shouldForceToSms': properties.shouldForceToSms,
    };
    return sha256.convert(utf8.encode(jsonEncode(projection))).toString();
  }

  String _logicalRouteChatScopeFingerprint(List<Map<String, dynamic>> chats) {
    final projection = chats.map((chat) {
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
      final sameExternal = external != null && _logicalSameSet(external, acceptedExternal);
      // A related group identity with a different external participant set is
      // a classified historical/different-set candidate, not an unresolved
      // execution route. Exact external-set parity is required before a new
      // physical identity can block and enter evidence-driven admission.
      if (sameExternal) {
        potential[rowId] = guid;
      }
    }
    return potential;
  }

  Future<bool> _advanceLogicalReadCertificate(
    LogicalConversationReadCertificate definition,
    List<Map<String, dynamic>> scope,
    List<LogicalRouteCandidateEvidence> certified,
    Map<int, String> unadmitted,
    List<LogicalAddressEvidence> vettedAliases, {
    required String accountContextFingerprint,
  }) async {
    final targetLogicalId = LogicalConversationId.certified(definition.id);
    final currentDefinition = LogicalConversationViewPolicy.certificateForLogicalId(targetLogicalId);
    final context = _currentLogicalCandidateContext(targetLogicalId);
    if (certified.isEmpty ||
        currentDefinition?.revision != definition.revision ||
        context == null ||
        context.certificateRevision != definition.revision ||
        context.providerAccountFingerprint != accountContextFingerprint) {
      return false;
    }
    final vetted = vettedAliases
        .map(LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress)
        .whereType<String>()
        .toSet();
    final acceptedExternal = _logicalExternalParticipants(certified.first.participants, vetted);
    if (acceptedExternal == null) return false;
    for (final candidate in certified.skip(1)) {
      final candidateExternal = _logicalExternalParticipants(candidate.participants, vetted);
      if (candidateExternal == null || !_logicalSameSet(candidateExternal, acceptedExternal)) {
        return false;
      }
    }
    if (certified.any(
      (candidate) => !context.matchesCandidate(service: candidate.sourceService, participants: candidate.participants),
    )) {
      return false;
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(accountContextFingerprint)) return false;
    final certifiedServices = certified
        .map((candidate) => candidate.sourceService)
        .where((service) => service.isNotEmpty)
        .toSet();
    if (certifiedServices.isEmpty) return false;

    final exactParticipantSetFingerprint = _logicalCandidateFingerprint(
      'exact-normalized-external-participant-set',
      acceptedExternal.toList()..sort(),
    );
    final accountFingerprint = _logicalCandidateFingerprint('provider-account-context', <String>[
      accountContextFingerprint,
    ]);
    final nominatorFingerprint = _logicalCandidateFingerprint('candidate-nominator-authority', <String>[
      targetLogicalId.value,
      'complete-provider-scope-v1',
    ]);
    final ordered = unadmitted.entries.toList()..sort((left, right) => left.key.compareTo(right.key));
    final nominations = <int, LogicalCandidateNomination>{};
    for (final entry in ordered) {
      final scoped = scope
          .where(
            (item) => (item['originalROWID'] as num?)?.toInt() == entry.key && item['guid']?.toString() == entry.value,
          )
          .toList(growable: false);
      final service = _logicalChatService(entry.value);
      if (scoped.length != 1 || service.isEmpty || !certifiedServices.contains(service)) continue;
      final candidate = PhysicalConversationRef.fromStablePhysicalGuid(entry.value);
      final serviceFingerprint = _logicalCandidateFingerprint('provider-service', <String>[service]);
      final nomination = LogicalCandidateNomination(
        candidate: candidate,
        targetLogicalId: targetLogicalId,
        exactParticipantSetFingerprint: exactParticipantSetFingerprint,
        serviceFingerprint: serviceFingerprint,
        accountFingerprint: accountFingerprint,
        nominationEvidenceFingerprint: _logicalCandidateFingerprint('candidate-nomination-evidence', <String>[
          candidate.fingerprint,
          targetLogicalId.value,
          exactParticipantSetFingerprint,
          serviceFingerprint,
          accountFingerprint,
          definition.revision,
        ]),
        nominatorFingerprint: nominatorFingerprint,
      );
      final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
      final transition = await _commitLogicalCandidateTransition(
        (working) => working.nominate(
          nomination,
          nowEpochMs: nowEpochMs,
          quarantineDurationMs: _logicalCandidateQuarantineDurationMs,
        ),
        nowEpochMs: nowEpochMs,
      );
      final phase = transition.record?.phase;
      if (phase != LogicalCandidateQuarantinePhase.rejected &&
          phase != LogicalCandidateQuarantinePhase.expiredVisible &&
          transition.record != null) {
        nominations[entry.key] = nomination;
      }
    }
    if (nominations.isEmpty) return false;

    final certifiedRows = definition.sourceChatRowIds;
    final certifiedScope = scope.where((item) => certifiedRows.contains((item['originalROWID'] as num?)?.toInt()));
    final certifiedGroupIds = certifiedScope
        .map((item) => item['groupId']?.toString())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet();
    final certifiedPhotos = certified
        .map((candidate) => candidate.groupPhotoGuid)
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet();
    final certifiedMessageOwners = <String, List<({int rowId, LogicalRouteMessageEvidence message})>>{};
    for (final candidate in certified) {
      for (final message in candidate.messages) {
        certifiedMessageOwners
            .putIfAbsent(
              message.messageGuid.toUpperCase(),
              () => <({int rowId, LogicalRouteMessageEvidence message})>[],
            )
            .add((rowId: candidate.sourceChatRowId, message: message));
      }
    }

    final evidence = <LogicalConversationCandidateEvidence>[];
    final rawChatsToSync = <Map<String, dynamic>>[];
    for (final entry in ordered) {
      if (!nominations.containsKey(entry.key)) continue;
      final scoped = scope
          .where(
            (item) => (item['originalROWID'] as num?)?.toInt() == entry.key && item['guid']?.toString() == entry.value,
          )
          .toList(growable: false);
      if (scoped.length != 1) continue;
      final firstResponse = await HttpSvc.chat.fetchOne(entry.value, withQuery: 'participants');
      final secondResponse = await HttpSvc.chat.fetchOne(entry.value, withQuery: 'participants');
      final firstRaw = firstResponse.data?['data'];
      final secondRaw = secondResponse.data?['data'];
      if (firstRaw is! Map || secondRaw is! Map) continue;
      final first = Map<String, dynamic>.from(firstRaw.cast<String, dynamic>());
      final second = Map<String, dynamic>.from(secondRaw.cast<String, dynamic>());
      final snapshot = await _collectLogicalRouteMessageSnapshot(entry.value);
      final identityStable =
          snapshot.complete &&
          (first['originalROWID'] as num?)?.toInt() == entry.key &&
          first['guid']?.toString() == entry.value &&
          first['groupId']?.toString() == scoped.single['groupId']?.toString() &&
          _logicalChatRouteFingerprint(first) == _logicalChatRouteFingerprint(second);

      final participants = <LogicalAddressEvidence>[];
      final rawParticipants = first['participants'];
      if (rawParticipants is List) {
        for (final item in rawParticipants.whereType<Map>()) {
          final address = item['address']?.toString();
          if (address != null && address.isNotEmpty) {
            participants.add(LogicalAddressEvidence(address: address, country: item['country']?.toString()));
          }
        }
      }
      final external = _logicalExternalParticipants(participants, vetted);
      final exactExternal = external != null && _logicalSameSet(external, acceptedExternal);

      final messages = <LogicalRouteMessageEvidence>[];
      var messageSnapshotComplete = snapshot.complete;
      for (final raw in snapshot.messages) {
        final rowId = (raw['originalROWID'] as num?)?.toInt();
        final guid = raw['guid']?.toString();
        final createdAt = (raw['dateCreated'] as num?)?.toInt();
        final error = (raw['error'] as num?)?.toInt();
        final itemType = (raw['itemType'] as num?)?.toInt();
        final isFromMe = raw['isFromMe'];
        if (rowId == null ||
            rowId <= 0 ||
            guid == null ||
            guid.isEmpty ||
            createdAt == null ||
            createdAt <= 0 ||
            error == null ||
            itemType == null ||
            isFromMe is! bool) {
          messageSnapshotComplete = false;
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
            associatedMessageGuid: raw['associatedMessageGuid']?.toString(),
            replyToGuid:
                raw['threadOriginatorGuid']?.toString() ??
                raw['threadOriginatorGUID']?.toString() ??
                raw['replyToGuid']?.toString(),
            account: raw['account']?.toString() ?? '',
          ),
        );
      }
      if (messages.length != snapshot.messages.length) messageSnapshotComplete = false;

      final candidateMessages = {for (final message in messages) message.messageGuid.toUpperCase(): message};
      final relationshipPeers = <int>{};
      final relationshipEdges = <String>{};
      for (final message in messages) {
        if (message.error != 0 || message.itemType != 0) continue;
        for (final target in _logicalRelationshipTargets(message)) {
          final owners = certifiedMessageOwners[target] ?? const [];
          if (owners.length != 1) continue;
          final owner = owners.single;
          if ((!owner.message.isInboundNormal && !owner.message.isSuccessfulOutbound) ||
              owner.message.createdAtEpoch > message.createdAtEpoch) {
            continue;
          }
          relationshipPeers.add(owner.rowId);
          relationshipEdges.add('${message.messageGuid.toUpperCase()}->$target');
        }
      }
      for (final certifiedCandidate in certified) {
        for (final message in certifiedCandidate.messages) {
          if (message.error != 0 || message.itemType != 0) continue;
          for (final target in _logicalRelationshipTargets(message)) {
            final targetMessage = candidateMessages[target];
            if (targetMessage == null ||
                (!targetMessage.isInboundNormal && !targetMessage.isSuccessfulOutbound) ||
                targetMessage.createdAtEpoch > message.createdAtEpoch) {
              continue;
            }
            relationshipPeers.add(certifiedCandidate.sourceChatRowId);
            relationshipEdges.add('${message.messageGuid.toUpperCase()}->$target');
          }
        }
      }

      final properties = _logicalChatGenerationProperties(first);
      final groupId = scoped.single['groupId']?.toString();
      final groupContinuity =
          (groupId != null && groupId.isNotEmpty && certifiedGroupIds.contains(groupId)) ||
          (properties.groupPhotoGuid != null && certifiedPhotos.contains(properties.groupPhotoGuid));
      final passiveNatural = messages.any((message) => message.isInboundNormal || message.isSuccessfulOutbound);
      final evidencePayload = <String, dynamic>{
        'schema': logicalConversationEvidenceReconciliationSchema,
        'rowId': entry.key,
        'guidSha256': sha256.convert(utf8.encode('logical-provider-guid-v1\u0000${entry.value}')).toString(),
        'certificateRevision': definition.revision,
        'identityStable': identityStable,
        'messageSnapshotComplete': messageSnapshotComplete,
        'exactExternal': exactExternal,
        'relationshipPeers': relationshipPeers.toList()..sort(),
        'relationshipEdges': relationshipEdges.toList()..sort(),
        'groupContinuity': groupContinuity,
        'passiveNatural': passiveNatural,
      };
      evidence.add(
        LogicalConversationCandidateEvidence(
          sourceChatRowId: entry.key,
          sourceChatGuidSha256: evidencePayload['guidSha256'] as String,
          admissionEvidenceSha256: sha256.convert(utf8.encode(jsonEncode(evidencePayload))).toString(),
          providerBackedAppleIdentity: identityStable,
          stableCompleteSnapshots: identityStable && messageSnapshotComplete,
          exactNormalizedExternalParticipants: exactExternal,
          pairwiseComparedSourceRowIds: exactExternal ? certifiedRows : const <int>{},
          directRelationshipPeerRowIds: relationshipPeers,
          structuredRelationshipCount: relationshipEdges.length,
          passiveNaturalProduction: passiveNatural,
          groupIdentityContinuity: groupContinuity,
          historicalLineage: groupContinuity || relationshipEdges.isNotEmpty,
          explanation:
              'Stable provider-backed Apple identity, complete snapshots, exact external participants, complete '
              'pairwise comparison, and direct structured natural lineage independently admit this read member.',
        ),
      );
      rawChatsToSync.add(scoped.single);
    }
    if (evidence.isEmpty) return false;

    final reconciliationAuthorityFingerprint = _logicalCandidateFingerprint(
      'candidate-reconciliation-authority',
      <String>[targetLogicalId.value, logicalConversationEvidenceReconciliationSchema],
    );
    final independentlyReconciled = <LogicalConversationCandidateEvidence>[];
    for (final candidateEvidence in evidence) {
      final nomination = nominations[candidateEvidence.sourceChatRowId];
      if (nomination == null) continue;
      final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
      final transition = await _commitLogicalCandidateTransition(
        (working) => working.applyEvidence(
          LogicalCandidateEvidence.reconciliation(
            candidate: nomination.candidate,
            targetLogicalId: nomination.targetLogicalId,
            sequence: 1,
            exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
            serviceFingerprint: nomination.serviceFingerprint,
            accountFingerprint: nomination.accountFingerprint,
            evidenceFingerprint: _logicalCandidateFingerprint('candidate-reconciliation-evidence', <String>[
              candidateEvidence.admissionEvidenceSha256,
              nomination.stableFingerprint,
            ]),
            authorityFingerprint: reconciliationAuthorityFingerprint,
          ),
          nowEpochMs: nowEpochMs,
        ),
        nowEpochMs: nowEpochMs,
      );
      if (transition.record?.phase == LogicalCandidateQuarantinePhase.reconciling ||
          transition.record?.phase == LogicalCandidateQuarantinePhase.certified) {
        independentlyReconciled.add(candidateEvidence);
      }
    }
    if (independentlyReconciled.isEmpty) return false;

    // Re-read the provider identity and complete chat scope immediately before
    // changing a certificate. Evidence collected under a prior account/scope
    // snapshot is never allowed to cross this local admission boundary.
    final accountRevalidation = _logicalAccountProjection((await HttpSvc.icloud.getAccountInfo()).data['data']);
    final scopeRevalidation = await _collectLogicalRouteChatScope();
    final currentRevalidationDefinition = LogicalConversationViewPolicy.certificateForLogicalId(targetLogicalId);
    final currentRevalidationContext = _currentLogicalCandidateContext(targetLogicalId);
    if (!scopeRevalidation.complete ||
        scopeRevalidation.fingerprint != _logicalRouteChatScopeFingerprint(scope) ||
        accountRevalidation.fingerprint != accountContextFingerprint ||
        currentRevalidationDefinition?.revision != definition.revision ||
        currentRevalidationContext?.certificateRevision != definition.revision ||
        currentRevalidationContext?.providerAccountFingerprint != accountContextFingerprint) {
      return false;
    }

    final reconciliation = LogicalConversationViewPolicy.reconcileCertificate(definition, independentlyReconciled);
    final certificateAdvanced = reconciliation.certificate.revision != definition.revision;
    final encodedCertificate = certificateAdvanced
        ? LogicalConversationViewPolicy.encodeReconciledRuntimeCertificate(reconciliation.certificate)
        : null;
    final certificateFingerprint = encodedCertificate == null
        ? null
        : _logicalCandidateFingerprint('independent-read-certificate', <String>[encodedCertificate]);
    final certificateAuthorityFingerprint = _logicalCandidateFingerprint('independent-certificate-authority', <String>[
      targetLogicalId.value,
      logicalConversationReadCertificateSchema,
    ]);
    final decisionsByRow = <int, LogicalConversationCandidateDecision>{
      for (final decision in reconciliation.decisions) decision.sourceChatRowId: decision,
    };
    var admittedCandidateStateReady = true;
    for (final candidateEvidence in independentlyReconciled) {
      final nomination = nominations[candidateEvidence.sourceChatRowId]!;
      final decision = decisionsByRow[candidateEvidence.sourceChatRowId];
      final admitted =
          certificateFingerprint != null &&
          decision?.classification ==
              LogicalConversationCandidateClassification.certifiedCurrentOrHistoricalReadMember &&
          reconciliation.certificate.containsSourceRowId(candidateEvidence.sourceChatRowId);
      final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
      final transition = await _commitLogicalCandidateTransition(
        (working) => working.applyEvidence(
          admitted
              ? LogicalCandidateEvidence.independentCertificate(
                  candidate: nomination.candidate,
                  targetLogicalId: nomination.targetLogicalId,
                  sequence: 2,
                  exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
                  serviceFingerprint: nomination.serviceFingerprint,
                  accountFingerprint: nomination.accountFingerprint,
                  evidenceFingerprint: _logicalCandidateFingerprint('candidate-certificate-evidence', <String>[
                    candidateEvidence.admissionEvidenceSha256,
                    certificateFingerprint,
                    decision!.reason,
                  ]),
                  authorityFingerprint: certificateAuthorityFingerprint,
                  certificateFingerprint: certificateFingerprint,
                )
              : LogicalCandidateEvidence.rejection(
                  candidate: nomination.candidate,
                  targetLogicalId: nomination.targetLogicalId,
                  sequence: 2,
                  exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
                  serviceFingerprint: nomination.serviceFingerprint,
                  accountFingerprint: nomination.accountFingerprint,
                  evidenceFingerprint: _logicalCandidateFingerprint('candidate-rejection-evidence', <String>[
                    candidateEvidence.admissionEvidenceSha256,
                    decision?.classification.name ?? 'missing-decision',
                    decision?.reason ?? 'MISSING_CANDIDATE_DECISION',
                  ]),
                  authorityFingerprint: certificateAuthorityFingerprint,
                ),
          nowEpochMs: nowEpochMs,
        ),
        nowEpochMs: nowEpochMs,
      );
      if (admitted &&
          (transition.record?.canJoinLogicalProjection != true ||
              transition.record?.certificateFingerprint != certificateFingerprint)) {
        admittedCandidateStateReady = false;
      }
    }
    if (!certificateAdvanced || encodedCertificate == null || !admittedCandidateStateReady) return false;
    final admittedRows = reconciliation.certificate.sourceChatRowIds.difference(definition.sourceChatRowIds);
    if (admittedRows.isEmpty || admittedRows.any((rowId) => !nominations.containsKey(rowId))) return false;

    // The background isolate binds the durable certificate against its own
    // database inventory. Mirror the already provider-proven source before
    // activation so it cannot reject a valid exact target merely because the
    // UI discovered the source ahead of the local ObjectBox observer.
    final admittedChats = rawChatsToSync
        .where((item) => admittedRows.contains((item['originalROWID'] as num?)?.toInt()))
        .toList(growable: false);
    if (admittedChats.isNotEmpty) await ChatInterface.bulkSyncChats(chatsData: admittedChats);

    // Stop every receipt minted under the predecessor certificate before the
    // first durable/isolate await. Certificate advancement is monotonic, so
    // row/GUID membership alone cannot detect a stale in-flight receipt.
    if (definition.id == LogicalConversationViewPolicy.bankedLogicalConversationId) {
      _invalidateBuild99LogicalAuthority('LOGICAL_READ_CERTIFICATE_ADVANCING', scheduleRecheck: false);
    }
    final transaction = await PrefsSvc.messaging.commitLogicalReadCertificateAdvancement(
      runtimeCertificateJson: encodedCertificate,
      expectedPersistedCertificateRevision: LogicalConversationViewPolicy.persistedRevisionForBoundCertificate(
        definition,
      ),
      activateAuthority: (_) async {
        if (!LogicalConversationViewPolicy.activateReconciledCertificate(
          reconciliation,
          expectedRevision: definition.revision,
        )) {
          return false;
        }
        return ChatInterface.activateLogicalReadCertificate(certificate: encodedCertificate);
      },
    );
    if (transaction.disposition == LogicalCertificateAdvancementDisposition.staleRevision) {
      return false;
    }
    if (!transaction.committed) {
      throw StateError('LOGICAL_READ_CERTIFICATE_ACTIVATION_FAILED');
    }
    _observeLogicalInventoryTransitions(reportChanges: false);
    _resetLogicalProjectionCursors(reconciliation.certificate.id);
    if (GetIt.I.isRegistered<EventDispatcher>()) {
      EventDispatcherSvc.emit(logicalMembershipAdvancedEvent, <String, dynamic>{
        'logicalId': reconciliation.certificate.id,
      });
    }
    _publishLogicalCandidateTransitionSideEffects();
    _scheduleLogicalCandidateReconciliation(delay: const Duration(milliseconds: 500));
    return true;
  }

  Set<String> _logicalRelationshipTargets(LogicalRouteMessageEvidence message) {
    final targets = <String>{};
    for (final value in [message.associatedMessageGuid, message.replyToGuid]) {
      if (value == null || value.isEmpty) continue;
      targets.add(value.replaceAll('bp:', '').split('/').last.toUpperCase());
    }
    return targets;
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
    return (
      fingerprint: LogicalConversationOutboundRoutePolicy.providerAccountSnapshotFingerprint(account),
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
      var evidence = await _collectLogicalRouteEvidence(chat);
      // Provider history that moved while it was being paged is re-read a
      // bounded number of times; it never becomes an authority decision.
      for (var attempt = 1; attempt < 3 && _logicalEvidenceNeedsSettle(evidence); attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 750));
        evidence = await _collectLogicalRouteEvidence(chat);
      }
      _logicalRouteEvidence = evidence;
      _logicalRouteEvidenceAt = DateTime.now();
      _logicalEvidenceObservationEpochTracker.complete(observationEpoch);
      return (evidence: evidence, observationEpoch: observationEpoch);
    } finally {
      if (identical(_logicalEvidenceMutex, mutex)) _logicalEvidenceMutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }

  bool _logicalEvidenceNeedsSettle(LogicalRouteEvidence evidence) =>
      evidence.candidates.isNotEmpty &&
      (!evidence.candidateScopeSnapshotComplete ||
          evidence.accountSnapshotBeforeSha256 != evidence.accountSnapshotAfterSha256 ||
          evidence.backendComputerId.isEmpty ||
          evidence.candidates.any(
            (candidate) => !candidate.chatSnapshotComplete || !candidate.messageSnapshotComplete,
          ));

  /// Resolves a batch from one complete evidence snapshot. Every decision and
  /// its revision therefore describe the same point-in-time provider truth.
  Future<
    ({
      List<LogicalRouteDecision> decisions,
      List<LogicalTransportReadinessEvidence> transportReadiness,
      LogicalAuthorityRevision? revision,
      int? observationEpoch,
      String? providerAccountSnapshotSha256,
      String? providerFactContractRevision,
    })
  >
  resolveLogicalMutationBatch(
    Chat chat,
    List<LogicalMutationRequest> requests, {
    bool force = false,
    bool passive = false,
  }) async {
    final observedAt = DateTime.now().millisecondsSinceEpoch;
    LogicalTransportReadinessEvidence unavailableEvidence(String reason) => LogicalTransportReadinessEvidence(
      service: 'UNKNOWN',
      state: LogicalTransportReadinessState.unknown,
      strength: LogicalTransportEvidenceStrength.unavailable,
      reason: reason,
      observedAtEpochMilliseconds: observedAt,
    );
    if (!hasBuild99WriterCapability(chat)) {
      final reason = isApprovedLogicalSource(chat)
          ? 'CERTIFIED_LOGICAL_WRITE_UNAVAILABLE'
          : 'NOT_A_CERTIFIED_LOGICAL_CONVERSATION';
      return (
        decisions: [for (final _ in requests) LogicalRouteDecision.notProven(reason)],
        transportReadiness: [for (final _ in requests) unavailableEvidence('TRANSPORT_ROUTE_NOT_QUALIFIED')],
        revision: null,
        observationEpoch: null,
        providerAccountSnapshotSha256: null,
        providerFactContractRevision: null,
      );
    }
    if (requests.any((request) => request.mutationClass == LogicalMutationClass.newMessage) &&
        !logicalRouteRuntimeStatus.value.hasEvaluated) {
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
          providerAccountSnapshotSha256: null,
          providerFactContractRevision: null,
        );
      }
      final authorityDecision = LogicalConversationOutboundRoutePolicy.resolve(
        evidence,
        const LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage),
      );
      final authority = LogicalConversationOutboundRoutePolicy.executionAuthority(evidence);
      final authorityMaterial = <String, dynamic>{
        'evidence': evidence.authorityRevision,
        'authority': authority?.revisionMaterial,
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
      _logicalPassiveRecheckFailures = 0;
      _logicalPassiveSupersededRechecks = 0;
      if (newMessageDecision != null) {
        final decision = decisions[newMessageDecision];
        final previous = logicalRouteRuntimeStatus.value;
        if (previous.authorityRevision != revision.authorityRevision || previous.authorityEpoch != revision.epoch) {
          Logger.info(
            'Logical write authority: state=${authority?.stateName ?? (decision.isSingleTarget ? 'SEND_READY' : 'SEND_BLOCKED')}, '
            'writer=${authority?.writerRoute ?? 'NONE'}, '
            'generation=${authority?.currentGenerationId?.substring(0, 12) ?? 'NONE'}, '
            'predicate=${decision.reason}, epoch=${revision.epoch}',
            tag: 'LogicalConversationRoute',
          );
        }
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
          authorityState: authority?.stateName,
          diagnostics: authority?.diagnostics(
            logicalConversationId: definition.id,
            certificateRevision: revision.certificateRevision,
            authorityRevision: revision.authorityRevision,
          ),
        );
      }
      return (
        decisions: decisions,
        transportReadiness: transportReadiness,
        revision: revision,
        observationEpoch: observation.observationEpoch,
        providerAccountSnapshotSha256: evidence.accountSnapshotAfterSha256,
        providerFactContractRevision: evidence.executionGenerationCertificate?.providerFactContractRevision,
      );
    } catch (error) {
      Logger.warn('Logical route evidence unavailable; mutation remains fail closed', tag: 'LogicalConversationRoute');
      _logicalAuthorityRevisionTracker.invalidate('CURRENT_ROUTE_EVIDENCE_UNAVAILABLE');
      final superseded = error is StateError && error.message == 'LOGICAL_EVIDENCE_OBSERVATION_COMPLETION_OUT_OF_ORDER';
      // A passive re-check that cannot reach the provider is transport
      // trouble, not authority evidence: keep the last proven presentation for
      // one bounded retry before reporting the evidence as unavailable. A
      // superseded observation is neither; the newer observation re-derives.
      if (passive && superseded && _logicalPassiveSupersededRechecks < 3) {
        _logicalPassiveSupersededRechecks += 1;
        _scheduleLogicalAuthorityRecheck(delay: const Duration(milliseconds: 250));
      } else if (passive && logicalRouteRuntimeStatus.value.isQualified && _logicalPassiveRecheckFailures < 1) {
        _logicalPassiveRecheckFailures += 1;
        _scheduleLogicalAuthorityRecheck(delay: const Duration(seconds: 15), deferToSooner: true);
      } else if (requests.any((request) => request.mutationClass == LogicalMutationClass.newMessage)) {
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
        providerAccountSnapshotSha256: null,
        providerFactContractRevision: null,
      );
    }
  }

  /// Resolves one mutation class from current server/source evidence. No
  /// mutation occurs here; this method only selects physical targets.
  Future<LogicalRouteDecision> resolveLogicalMutation(
    Chat chat,
    LogicalMutationRequest request, {
    bool force = false,
    bool passive = false,
  }) async {
    final result = await resolveLogicalMutationBatch(
      chat,
      <LogicalMutationRequest>[request],
      force: force,
      passive: passive,
    );
    return result.decisions.single;
  }

  /// Invalidates every admission binding immediately. The last evaluated
  /// presentation stays visible while one debounced passive re-check
  /// re-derives authority, so an invalidation that proves nothing changed never
  /// flashes the composer; execution boundaries always force fresh evidence.
  void _invalidateBuild99LogicalAuthority(String reason, {bool scheduleRecheck = true}) {
    _logicalRouteEvidence = null;
    _logicalRouteEvidenceAt = null;
    _logicalTransportReadinessBySourceRow.clear();
    _logicalEvidenceObservationEpochTracker.invalidate();
    final revision = _logicalAuthorityRevisionTracker.invalidate(reason);
    if (!logicalRouteRuntimeStatus.value.hasEvaluated) {
      logicalRouteRuntimeStatus.value = LogicalRouteRuntimeStatus(
        stage: LogicalRouteRuntimeStage.unchecked,
        reason: reason,
        certificateRevision: revision.certificateRevision,
        authorityRevision: revision.authorityRevision,
        authorityEpoch: revision.epoch,
      );
    }
    if (scheduleRecheck) _scheduleLogicalAuthorityRecheck();
  }

  /// Invalidates Comcast writer state only when [chat] belongs to, or is an
  /// evidence-backed candidate for, the banked Build 99 conversation.
  bool invalidateBuild99LogicalAuthority(Chat chat, String reason, {bool scheduleRecheck = true}) {
    if (!_canAffectBuild99WriterAuthority(chat)) return false;
    _invalidateBuild99LogicalAuthority(reason, scheduleRecheck: scheduleRecheck);
    return true;
  }

  /// Re-derives presentation authority after a blocked admission so a banner
  /// never outlives the evidence that produced it.
  bool requestLogicalAuthorityRecheck(Chat chat) {
    if (!_canAffectBuild99WriterAuthority(chat)) return false;
    _scheduleLogicalAuthorityRecheck(delay: const Duration(seconds: 3));
    return true;
  }

  void _scheduleLogicalAuthorityRecheck({Duration delay = const Duration(seconds: 2), bool deferToSooner = false}) {
    final dueAt = DateTime.now().add(delay);
    final pendingDueAt = _logicalAuthorityRecheckDueAt;
    if (deferToSooner &&
        _logicalAuthorityRecheckTimer?.isActive == true &&
        pendingDueAt != null &&
        pendingDueAt.isBefore(dueAt)) {
      return;
    }
    _logicalAuthorityRecheckTimer?.cancel();
    _logicalAuthorityRecheckDueAt = dueAt;
    _logicalAuthorityRecheckTimer = Timer(delay, () {
      _logicalAuthorityRecheckDueAt = null;
      final active = activeChat?.chat;
      Chat? chat = active != null && hasBuild99WriterCapability(active) ? active : null;
      if (chat == null) {
        final definition = _logicalDefinition;
        if (definition != null && definition.id == LogicalConversationViewPolicy.bankedLogicalConversationId) {
          final presentation = _presentationChatForDefinition(definition);
          if (presentation != null && hasBuild99WriterCapability(presentation)) chat = presentation;
        }
      }
      if (chat == null) return;
      unawaited(prepareLogicalRoute(chat, force: true, passive: true));
    });
  }

  int logicalDraftRevisionFor(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
    if (logicalId == null) return 0;
    return _logicalDraftPreviewRevisions[logicalId] ?? 0;
  }

  LogicalDraftPreview? logicalDraftPreviewFor(Chat chat) {
    if (!isLogicalConversation(chat)) return null;
    logicalDraftRevisionFor(chat);
    return LogicalDraftPreview.fromDraft(loadLogicalDraft(chat));
  }

  void _bumpLogicalDraftPreviewRevision(String logicalId) {
    _logicalDraftPreviewRevisions[logicalId] = (_logicalDraftPreviewRevisions[logicalId] ?? 0) + 1;
  }

  void _invalidateKnownLogicalDraftPreviews() {
    for (final logicalId in _logicalDraftPreviewRevisions.keys.toList(growable: false)) {
      _bumpLogicalDraftPreviewRevision(logicalId);
    }
  }

  LogicalDraft? loadLogicalDraft(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
    if (logicalId == null) return null;
    final raw = PrefsSvc.messaging.loadLogicalDraftJson(logicalId);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = LogicalDraft.fromJson(decoded.cast<String, dynamic>());
      return draft.logicalId == logicalId ? draft : null;
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
  }) => _withLogicalDraftLock(
    () => _saveLogicalDraftLocked(
      chat,
      text: text,
      subject: subject,
      attachments: attachments,
      reply: reply,
      effectId: effectId,
      expectedDraftGeneration: expectedDraftGeneration,
    ),
  );

  Future<LogicalDraft?> _saveLogicalDraftLocked(
    Chat chat, {
    required String text,
    required String subject,
    required List<LogicalAttachmentIntent> attachments,
    required LogicalReplyIntent? reply,
    String? effectId,
    int? expectedDraftGeneration,
  }) async {
    final entry = _registryEntryForChat(chat);
    final sourceRowId = chat.originalROWID;
    if (entry == null || sourceRowId == null || !entry.sourceChatRowIds.contains(sourceRowId)) {
      throw StateError('NOT_A_CERTIFIED_LOGICAL_CONVERSATION');
    }
    final logicalId = entry.logicalId.value;
    if (expectedDraftGeneration != null && (_logicalDraftGenerations[logicalId] ?? 0) != expectedDraftGeneration) {
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing =
        loadLogicalDraft(chat) ??
        LogicalDraft.create(
          logicalId: logicalId,
          nowEpochMilliseconds: now,
          observedRevision: hasBuild99WriterCapability(chat)
              ? _logicalAuthorityRevisionTracker.lastObserved ?? logicalWriterAuthorityRevisionFor(chat)
              : null,
        );
    final updated = existing.mergeUserIntent(
      text: text,
      subject: subject,
      attachments: attachments,
      reply: reply,
      effectId: effectId,
      updatedAtEpochMilliseconds: now,
    );
    await PrefsSvc.messaging.saveLogicalDraftJson(logicalId, jsonEncode(updated.toJson()));
    _bumpLogicalDraftPreviewRevision(logicalId);
    return updated;
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
    return _withLogicalDraftLock(() async {
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
      return _saveLogicalDraftLocked(
        chat,
        text: text,
        subject: subject,
        attachments: <LogicalAttachmentIntent>[...unavailable, ...currentAttachments],
        reply: reply,
        effectId: effectId,
        expectedDraftGeneration: expectedDraftGeneration,
      );
    });
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
      _bumpLogicalDraftPreviewRevision(draft.logicalId);
    });
  }

  Future<bool> clearLogicalDraftIfCurrent(LogicalDraft admittedDraft) {
    return _withLogicalDraftLock(() async {
      final currentRaw = PrefsSvc.messaging.loadLogicalDraftJson(admittedDraft.logicalId);
      if (currentRaw == null) {
        _bumpLogicalDraftPreviewRevision(admittedDraft.logicalId);
        return true;
      }
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
      _bumpLogicalDraftPreviewRevision(admittedDraft.logicalId);
      return true;
    });
  }

  Future<LogicalRouteDecision> prepareLogicalRoute(Chat chat, {bool force = false, bool passive = false}) =>
      resolveLogicalMutation(
        chat,
        const LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage),
        force: force,
        passive: passive,
      );

  bool _logicalSourcesMatchAvailableRegistryEntry(LogicalConversationRegistryEntry entry, List<Chat> sources) {
    if (sources.length != entry.runtimePhysicalRefs.length || sources.length != entry.sourceChatRowIds.length) {
      return false;
    }
    final refs = <PhysicalConversationRef>{};
    final rows = <int>{};
    for (final source in sources) {
      final rowId = source.originalROWID;
      if (rowId == null) return false;
      final ref = PhysicalConversationRef.fromStablePhysicalGuid(source.guid);
      if (!entry.containsRuntimeBinding(physicalRef: ref, sourceChatRowId: rowId)) return false;
      if (!refs.add(ref) || !rows.add(rowId)) return false;
    }
    return refs.length == entry.runtimePhysicalRefs.length &&
        refs.containsAll(entry.runtimePhysicalRefs) &&
        rows.length == entry.sourceChatRowIds.length &&
        rows.containsAll(entry.sourceChatRowIds);
  }

  bool _logicalSourcesExactlyMatchRegistryEntry(LogicalConversationRegistryEntry entry, List<Chat> sources) {
    return entry.runtimePhysicalRefs.length == entry.members.length &&
        entry.sourceChatRowIds.length == entry.members.length &&
        _logicalSourcesMatchAvailableRegistryEntry(entry, sources);
  }

  PhysicalConversationRef? _certifiedLogicalRefForSource(LogicalConversationRegistryEntry entry, Chat source) {
    final rowId = source.originalROWID;
    if (rowId == null) return null;
    return entry.certifiedRefForRuntimeBinding(
      physicalRef: PhysicalConversationRef.fromStablePhysicalGuid(source.guid),
      sourceChatRowId: rowId,
    );
  }

  LogicalUnreadConversationState? _synchronizeLogicalUnreadState({
    required LogicalConversationId logicalId,
    List<Chat>? sourceSnapshot,
  }) {
    final entry = _logicalRegistry.entryForLogicalId(logicalId);
    if (entry == null) return null;
    final sources = sourceSnapshot ?? _logicalSourceChatsForEntry(entry);
    final cached = _logicalUnreadStates.stateFor(logicalId);
    if (!_logicalSourcesMatchAvailableRegistryEntry(entry, sources)) {
      if (cached != null && cached.markReadOperationsInFlight > 0) {
        cached.syncPending = true;
        _refreshLogicalUnreadCompatibility(latest: cached);
      }
      return null;
    }

    final refsByGuid = <String, PhysicalConversationRef>{};
    for (final source in sources) {
      final ref = _certifiedLogicalRefForSource(entry, source);
      if (ref == null || refsByGuid.putIfAbsent(source.guid, () => ref) != ref) return null;
    }
    final cacheMatches = cached?.hasExactCertifiedSources(entry.certifiedMemberRefs) == true;
    if (!cacheMatches && cached != null && cached.markReadOperationsInFlight > 0) {
      cached.syncPending = true;
      _refreshLogicalUnreadCompatibility(latest: cached);
      return null;
    }

    var state = cached;
    var changed = false;
    if (!cacheMatches) {
      final expectedFingerprints = entry.certifiedMemberRefs.map((ref) => ref.fingerprint).toSet();
      final retained = <LogicalUnreadObservation>[];
      try {
        final raw = PrefsSvc.messaging.loadLogicalUnreadLedgerJson(logicalId.value);
        if (raw != null) {
          final restored = LogicalUnreadLedger.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
          retained.addAll(
            restored.observations.where((observation) => expectedFingerprints.contains(observation.source.fingerprint)),
          );
        }
      } catch (error, trace) {
        Logger.warn(
          'Discarding invalid reconstructible logical unread cache',
          error: error,
          trace: trace,
          tag: 'LogicalUnread',
        );
      }
      state = LogicalUnreadConversationState(
        logicalId: logicalId,
        ledger: LogicalUnreadLedger(certifiedSources: entry.certifiedMemberRefs, observations: retained),
        syncPending:
            PrefsSvc.messaging.loadLogicalReadSyncPending(logicalId.value) ||
            entry.runtimePhysicalRefs.length != entry.members.length,
      );
      _logicalUnreadStates.put(state);
      changed = true;
    }

    final activeState = state!;
    final ledger = activeState.ledger;
    final physicalSnapshot = <PhysicalConversationRef, bool>{
      for (final source in sources)
        refsByGuid[source.guid]!:
            activeState.hasPendingWatermark(refsByGuid[source.guid]!) || source.hasUnreadMessage == true,
    };
    final eventWatermarks = <PhysicalConversationRef, int>{
      for (final source in sources) refsByGuid[source.guid]!: activeState.messageWatermarkFor(refsByGuid[source.guid]!),
    };
    final completeSnapshot = entry.runtimePhysicalRefs.length == entry.members.length;
    changed =
        (completeSnapshot
            ? ledger.observePhysicalSnapshot(physicalSnapshot, eventWatermarks: eventWatermarks)
            : ledger.observeAvailablePhysicalSnapshot(physicalSnapshot, eventWatermarks: eventWatermarks)) ||
        changed;
    if (!completeSnapshot) {
      activeState.syncPending = true;
    }
    if (changed || !completeSnapshot) _scheduleLogicalUnreadPersistence(activeState);
    _refreshLogicalUnreadCompatibility(latest: activeState);
    return activeState;
  }

  LogicalRouteDecision _resolveCertifiedLogicalReadMutation(
    LogicalConversationRegistryEntry entry,
    List<Chat> sources,
    Set<int> unreadRows,
  ) {
    if (!_logicalSourcesExactlyMatchRegistryEntry(entry, sources)) {
      return const LogicalRouteDecision.notProven('LOGICAL_UNREAD_SOURCE_BINDING_INCOMPLETE');
    }
    if (unreadRows.any((rowId) => !entry.sourceChatRowIds.contains(rowId))) {
      return const LogicalRouteDecision.notProven('LOGICAL_UNREAD_TARGET_OUTSIDE_CERTIFICATE');
    }
    return LogicalRouteDecision.qualified('CERTIFIED_EXACT_UNREAD_SOURCE_SET', unreadRows.toList()..sort());
  }

  /// Applies an exact-source provider status event to local projection only.
  /// `privateMark: false` is mandatory: the provider already performed the
  /// transition, so observation must never issue a second read mutation.
  Future<bool> observeProviderChatReadStatus({required String sourceChatGuid, required bool read}) async {
    final source = findChatByGuid(sourceChatGuid) ?? Chat.findOne(guid: sourceChatGuid);
    if (source == null) return false;
    final hasUnread = !read;
    final entry = _registryEntryForChat(source);

    if (entry == null) {
      if (isApprovedLogicalSource(source)) return false;
      await source.toggleHasUnreadAsync(hasUnread, force: true, clearLocalNotifications: false, privateMark: false);
      getChatState(source.guid)?.updateHasUnreadInternal(hasUnread);
      _recalculateUnreadCount();
      _scheduleListVersionUpdate(immediate: true);
      return true;
    }

    final sources = _logicalSourceChatsForEntry(entry);
    final ref = _certifiedLogicalRefForSource(entry, source);
    final state = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
    if (ref == null || state == null || !sources.any((candidate) => candidate.guid == source.guid)) {
      return false;
    }

    await source.toggleHasUnreadAsync(hasUnread, force: true, clearLocalNotifications: false, privateMark: false);
    getChatState(source.guid)?.updateHasUnreadInternal(hasUnread);
    final observation = state.observeProviderReadStatus(source: ref, hasUnread: hasUnread);
    if (!hasUnread &&
        observation == LogicalUnreadObservationResult.staleIgnored &&
        state.ledger.observationFor(ref)?.hasUnread == true) {
      // The provider status carried no causal message watermark and could only
      // acknowledge an older admitted plan. Keep the newer inbound projected.
      await source.toggleHasUnreadAsync(true, force: true, clearLocalNotifications: false, privateMark: false);
      getChatState(source.guid)?.updateHasUnreadInternal(true);
    }
    state.syncPending = state.hasPendingWatermarks || entry.runtimePhysicalRefs.length != entry.members.length;
    _refreshLogicalUnreadCompatibility(latest: state);
    await _persistLogicalUnreadState(state);
    _syncLogicalPresentationState();
    _recalculateUnreadCount();
    _scheduleListVersionUpdate(immediate: true);
    return true;
  }

  /// Marks only the exact unread source set captured by the monotonic ledger.
  /// Provider failures are retained as partial acknowledgement; successful
  /// sources advance independently and no historical source is mutated merely
  /// because it belongs to the logical presentation union.
  Future<LogicalRouteDecision> markLogicalConversationRead(Chat chat) {
    final entry = _registryEntryForChat(chat);
    if (entry == null) {
      return Future<LogicalRouteDecision>.value(
        const LogicalRouteDecision.notProven('LOGICAL_UNREAD_LEDGER_UNAVAILABLE'),
      );
    }
    return _logicalMarkReadOperations.run(entry.logicalId.value, () => _executeMarkLogicalConversationRead(chat));
  }

  Future<LogicalRouteDecision> _executeMarkLogicalConversationRead(Chat chat) async {
    final entry = _registryEntryForChat(chat);
    final definition = entry == null ? null : LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
    if (entry == null || definition == null) {
      return const LogicalRouteDecision.notProven('LOGICAL_UNREAD_LEDGER_UNAVAILABLE');
    }
    final sources = _logicalSourceChats(definition);
    final state = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
    if (state == null) {
      return const LogicalRouteDecision.notProven('LOGICAL_UNREAD_SOURCE_BINDING_INCOMPLETE');
    }
    final ledger = state.ledger;
    final sourceByFingerprint = <String, Chat>{};
    final refByRow = <int, PhysicalConversationRef>{};
    for (final source in sources) {
      final rowId = source.originalROWID;
      final ref = _certifiedLogicalRefForSource(entry, source);
      if (rowId == null ||
          ref == null ||
          sourceByFingerprint.putIfAbsent(ref.fingerprint, () => source) != source ||
          refByRow.putIfAbsent(rowId, () => ref) != ref) {
        return const LogicalRouteDecision.notProven('LOGICAL_UNREAD_SOURCE_BINDING_INCOMPLETE');
      }
    }
    final plan = ledger.markReadPlan();
    final unreadRows = plan.entries
        .map((entry) => sourceByFingerprint[entry.source.fingerprint]?.originalROWID)
        .whereType<int>()
        .toSet();
    if (unreadRows.length != plan.entries.length) {
      return const LogicalRouteDecision.notProven('LOGICAL_UNREAD_SOURCE_BINDING_INCOMPLETE');
    }
    final decision = _resolveCertifiedLogicalReadMutation(entry, sources, unreadRows);
    if (!decision.isQualified) return decision;

    state.beginMarkRead(plan);
    var outcome = LogicalMarkReadOutcome.partial;
    try {
      final receipts = <LogicalMarkReadReceipt>[];
      for (final rowId in decision.physicalTargetRowIds) {
        final source = sources.firstWhere((candidate) => candidate.originalROWID == rowId);
        final ref = refByRow[rowId]!;
        final planned = plan.entries.firstWhere((entry) => entry.source == ref);

        LogicalMarkReadReceipt receiptForCurrentState({required bool providerRequestSucceeded}) {
          final refreshed = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
          final current = ledger.observationFor(ref);
          if (!identical(refreshed, state) ||
              current == null ||
              current.eventWatermark != planned.observedEventWatermark) {
            return LogicalMarkReadReceipt.failure(source: ref, plannedRevision: planned.observedRevision);
          }
          if (!current.hasUnread && current.revision > planned.observedRevision) {
            return LogicalMarkReadReceipt.success(
              source: ref,
              plannedRevision: planned.observedRevision,
              resultRevision: current.revision,
            );
          }
          if (providerRequestSucceeded && current.hasUnread && current.revision == planned.observedRevision) {
            return LogicalMarkReadReceipt.success(
              source: ref,
              plannedRevision: planned.observedRevision,
              resultRevision: planned.observedRevision + 1,
            );
          }
          return LogicalMarkReadReceipt.failure(source: ref, plannedRevision: planned.observedRevision);
        }

        try {
          await HttpSvc.chat.markRead(source.guid);
          receipts.add(receiptForCurrentState(providerRequestSucceeded: true));
        } catch (error, trace) {
          Logger.warn(
            'Logical read acknowledgement failed for one source',
            error: error,
            trace: trace,
            tag: 'LogicalUnread',
          );
          receipts.add(receiptForCurrentState(providerRequestSucceeded: false));
        }
      }

      final refreshed = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
      outcome = identical(refreshed, state)
          ? ledger.applyMarkReadReceipts(plan, receipts, stalePlanAsPartial: true)
          : LogicalMarkReadOutcome.partial;

      for (final receipt in receipts.where((receipt) => receipt.succeeded)) {
        final source = sourceByFingerprint[receipt.source.fingerprint]!;
        final planned = plan.entries.firstWhere((entry) => entry.source == receipt.source);
        final current = ledger.observationFor(receipt.source);
        if (current?.hasUnread == false && current?.revision == receipt.resultRevision) {
          state.clearPendingThrough(receipt.source, planned.observedEventWatermark);
          try {
            await source.toggleHasUnreadAsync(false, force: true, clearLocalNotifications: false, privateMark: false);
          } catch (error, trace) {
            Logger.warn(
              'Logical local read projection failed for one source',
              error: error,
              trace: trace,
              tag: 'LogicalUnread',
            );
            ledger.observe(
              LogicalUnreadObservation(
                source: receipt.source,
                revision: current!.revision + 1,
                hasUnread: true,
                eventWatermark: current.eventWatermark,
              ),
            );
            state.retainPending(receipt.source, current.eventWatermark);
            outcome = LogicalMarkReadOutcome.partial;
          }
        }
      }

      for (final observation in ledger.observations.where((entry) => entry.hasUnread)) {
        final source = sourceByFingerprint[observation.source.fingerprint];
        if (source != null) {
          state.retainPending(observation.source, observation.eventWatermark);
          if (source.hasUnreadMessage != true) {
            try {
              await source.toggleHasUnreadAsync(true, force: true, clearLocalNotifications: false, privateMark: false);
            } catch (error, trace) {
              Logger.warn(
                'Logical pending unread projection could not be restored',
                error: error,
                trace: trace,
                tag: 'LogicalUnread',
              );
            }
          }
        }
      }
      if (ledger.hasUnread || state.hasPendingWatermarks) {
        outcome = LogicalMarkReadOutcome.partial;
      }

      state.lastOutcome = outcome;
      state.syncPending = outcome == LogicalMarkReadOutcome.partial;
      _refreshLogicalUnreadCompatibility(latest: state);
      await _persistLogicalUnreadState(state);

      final finalState = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
      if (!identical(finalState, state) || ledger.hasUnread || state.hasPendingWatermarks) {
        outcome = LogicalMarkReadOutcome.partial;
        state.lastOutcome = outcome;
        state.syncPending = true;
        _refreshLogicalUnreadCompatibility(latest: state);
        await _persistLogicalUnreadState(state);
      }

      _syncLogicalPresentationState();
      if (outcome != LogicalMarkReadOutcome.partial && !ledger.hasUnread) {
        if (kIsDesktop) {
          await NotificationsSvc.clearDesktopNotificationsForChat(presentationChatFor(chat).guid);
        } else if (!kIsWeb) {
          final notificationTargets = LogicalPlatformCleanupPlan.notificationTargets(
            logicalId: entry.logicalId,
            legacyPhysicalIds: sources.map((source) => source.id),
            ordinaryTag: NotificationsService.NEW_MESSAGE_TAG,
          );
          for (final target in notificationTargets) {
            await MethodChannelSvc.actions.deleteNotification(notificationId: target.id, tag: target.tag);
          }
        }
      }
    } finally {
      state.endMarkRead();
      _refreshLogicalUnreadCompatibility(latest: state);
    }
    return decision;
  }

  String presentationGuidFor(String guid) {
    final chat =
        findChatByGuid(guid) ?? _registeredLogicalChats().firstWhereOrNull((candidate) => candidate.guid == guid);
    return chat == null ? guid : presentationChatFor(chat).guid;
  }

  List<Chat> _projectLogicalChatList(Iterable<Chat> rawChats) {
    final registry = _logicalRegistry;
    final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
    final visible = rawChats.where(
      (chat) => !_isLogicalCandidateTemporarilySuppressed(chat, registry, nowEpochMs: nowEpochMs),
    );
    final projected = registry.projectConversationList(visible, (chat) => chat.originalROWID);
    projected.sort(_sortCompare);
    return projected;
  }

  void _syncLogicalPresentationState() {
    for (final entry in _logicalRegistry.entries) {
      final sources = _logicalSourceChatsForEntry(entry);
      final presentation = _presentationChatForEntry(entry);
      if (presentation == null) continue;
      final presentationState = chatStates[presentation.guid];
      if (presentationState == null) continue;

      final latestMessages = sources.map((source) => source.dbLatestMessage.target).whereType<Message>().toList()
        ..sort(compareLogicalMessagesDescending);
      if (latestMessages.isNotEmpty) {
        final latest = latestMessages.first;
        presentationState.updateLatestMessageInternal(latest);
        final redacted = SettingsSvc.settings.redactedMode.value;
        presentationState.updateSubtitleInternal(
          latest.getNotificationText(
            hideContactInfo: redacted && SettingsSvc.settings.hideContactInfo.value,
            hideMessageContent: redacted && SettingsSvc.settings.hideMessageContent.value,
          ),
        );
      }

      final currentActive = activeChat;
      if (currentActive != null &&
          conversationKeyFor(currentActive.chat) == entry.logicalId.value &&
          !identical(currentActive, presentationState)) {
        final openController = currentActive.controller;
        currentActive.controller = null;
        currentActive.updateActiveAndAliveInternal(false);
        presentationState.controller = openController;
        activeChat = presentationState;
        presentationState.updateActiveAndAliveInternal(true);
        openController?.rebindPresentation(presentation);
      }
      final synchronized = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
      final cached = synchronized ?? _logicalUnreadStates.stateFor(entry.logicalId);
      final unread = (cached?.ledger.hasUnread ?? false) || sources.any((source) => source.hasUnreadMessage == true);
      presentationState.updateHasUnreadInternal(unread);
    }
  }

  void _refreshLogicalPresentation({bool immediate = true}) {
    _syncLogicalPresentationState();
    for (final entry in _logicalRegistry.entries) {
      final presentation = _presentationChatForEntry(entry);
      if (presentation != null) _repositionChat(presentation, immediate: immediate);
    }
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
        chats = chats.where(isConversationArchived).toList();
      } else {
        chats = chats.where((e) => !isConversationArchived(e)).toList();
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
        chats = chats.where(isConversationMuted).toList();
      } else if (filters.muteFilter == ChatMuteFilter.unmuted) {
        chats = chats.where((e) => !isConversationMuted(e)).toList();
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
        chats = chats
            .where((chat) => filters.customGroupIds.any((id) => isConversationInCustomGroup(chat, id)))
            .toList();
      }
    }

    // Apply pinned filter
    if (pinnedOnly == true) {
      chats = chats.where(isConversationPinned).toList();
    } else if (excludePinned == true) {
      chats = chats.where((e) => !isConversationPinned(e)).toList();
    }

    return chats;
  }

  /// Get only group chats
  List<Chat> get groupChats {
    return allChats.where((c) => c.isGroup).toList();
  }

  /// Get pinned chats
  List<Chat> get pinnedChats {
    return getSortedChats().where(isConversationPinned).toList()
      ..sort((a, b) => (conversationPinIndex(a) ?? 0).compareTo(conversationPinIndex(b) ?? 0));
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
    await _restoreLogicalCandidateQuarantine();
    await _restoreLogicalCandidateContexts();

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

        if (activeChatGuid.value == conversationKeyFor(c)) {
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
    _observeLogicalInventoryTransitions(reportChanges: false);
    await _restoreLogicalSettings();
    final candidateNowEpochMs = DateTime.now().millisecondsSinceEpoch;
    final restoredCandidates = _logicalCandidateQuarantine.recordsAt(nowEpochMs: candidateNowEpochMs);
    _scheduleLogicalCandidateQuarantinePersistence(candidateNowEpochMs);
    if (restoredCandidates.any(
      (record) =>
          logicalCandidateTargets(record, LogicalConversationViewPolicy.bankedApplicationLogicalId) &&
          (record.phase == LogicalCandidateQuarantinePhase.nominated ||
              record.phase == LogicalCandidateQuarantinePhase.reconciling ||
              record.phase == LogicalCandidateQuarantinePhase.certified),
    )) {
      _scheduleLogicalAuthorityRecheck();
    }
    _scheduleLogicalCandidateReconciliation(delay: Duration.zero);

    // Calculate initial unread count now that all chat states are populated.
    // The listener only fires on changes, so we need an explicit call here to
    // seed the badge with the correct value before any message is received.
    _recalculateUnreadCount();
    await _reconcileDeferredLogicalNotifications();

    if (kIsDesktop) {
      unawaited(
        DesktopNotifications.cancelStale(
          keepGroups: presentationChatStates
              .where((state) => state.hasUnreadMessage.value)
              .map((state) => conversationKeyFor(state.chat))
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
    final registry = _logicalRegistry;
    final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
    var count = chatStates.values
        .where(
          (state) =>
              state.hasUnreadMessage.value &&
              shouldCountPhysicalUnreadAsOrdinary(
                certifiedSource: isApprovedLogicalSource(state.chat),
                temporarilySuppressed: _isLogicalCandidateTemporarilySuppressed(
                  state.chat,
                  registry,
                  nowEpochMs: nowEpochMs,
                ),
              ),
        )
        .length;
    for (final entry in _logicalRegistry.entries) {
      final sources = _logicalSourceChatsForEntry(entry);
      final synchronized = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
      final cached = synchronized ?? _logicalUnreadStates.stateFor(entry.logicalId);
      if ((cached?.ledger.hasUnread ?? false) || sources.any((source) => source.hasUnreadMessage == true)) {
        count++;
      }
    }
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
    final aIsPinned = isConversationPinned(a);
    final bIsPinned = isConversationPinned(b);
    final aPinIndex = conversationPinIndex(a);
    final bPinIndex = conversationPinIndex(b);

    // Both pinned with an explicit order → sort by pinIndex.
    if (aIsPinned && bIsPinned && aPinIndex != null && bPinIndex != null) {
      return aPinIndex.compareTo(bPinIndex);
    }

    // b is ordered-pinned, a is not → b comes first.
    if (bIsPinned && bPinIndex != null && (!aIsPinned || aPinIndex == null)) {
      return 1;
    }
    // a is ordered-pinned, b is not → a comes first.
    if (aIsPinned && aPinIndex != null && (!bIsPinned || bPinIndex == null)) {
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
      final authorityShapeChanged = _logicalAuthorityShapeChanged(state, updated);
      if (authorityShapeChanged) {
        if (_canAffectBuild99WriterAuthority(state.chat) || _canAffectBuild99WriterAuthority(updated)) {
          _invalidateBuild99LogicalAuthority('LOGICAL_SOURCE_AUTHORITY_SHAPE_CHANGED');
        }
        final contextRelevant =
            isApprovedLogicalSource(state.chat) ||
            isApprovedLogicalSource(updated) ||
            _logicalCandidateContextMatchForChat(state.chat).kind != LogicalCandidateContextMatchKind.none ||
            _logicalCandidateContextMatchForChat(updated).kind != LogicalCandidateContextMatchKind.none;
        if (contextRelevant) _scheduleLogicalCandidateReconciliation();
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
    final isNewInventoryBinding = !chatStates.containsKey(toAdd.guid);
    if (isNewInventoryBinding && _matchesCertifiedProviderProof(toAdd)) {
      LogicalConversationDatabaseCertificateBinding.rebindActiveCertificates(
        arrivingBindings: <LogicalConversationPhysicalChatBinding>[
          LogicalConversationPhysicalChatBinding.fromProviderGuid(
            sourceChatRowId: toAdd.originalROWID!,
            sourceChatGuid: toAdd.guid,
          ),
        ],
      );
    }
    // A newly observed group chat can be a route candidate. Conservatively
    // invalidate admission state until a forced provider observation proves it.
    // Re-adding a known chat or observing a one-to-one chat cannot.
    if (isNewInventoryBinding && _canAffectBuild99WriterAuthority(toAdd)) {
      _invalidateBuild99LogicalAuthority('PHYSICAL_CHAT_CANDIDATE_OBSERVED');
    }
    if (isNewInventoryBinding &&
        (isApprovedLogicalSource(toAdd) ||
            toAdd.style == 43 ||
            _logicalCandidateContextMatchForChat(toAdd).kind != LogicalCandidateContextMatchKind.none)) {
      _scheduleLogicalCandidateReconciliation(delay: const Duration(milliseconds: 250));
    }
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
    _observeLogicalInventoryTransitions(reportChanges: true);

    // _sortedChats isn't reactive; bump the list version so the UI rebuilds.
    _scheduleListVersionUpdate(immediate: immediate);
  }

  void removeChat(Chat toRemove) {
    if (headless) return;
    if (_canAffectBuild99WriterAuthority(toRemove)) {
      _invalidateBuild99LogicalAuthority('PHYSICAL_CHAT_REMOVAL_OBSERVED');
    }
    if (isPotentialLogicalSource(toRemove)) return;
    chatStates.remove(toRemove.guid);
    _sortedChats.removeWhere((c) => c.guid == toRemove.guid);
    _scheduleListVersionUpdate(immediate: true);
  }

  /// Marks unread chats as read. When [chatGuids] is provided, only chats in
  /// that set are affected (e.g. the currently filtered/visible subset) —
  /// otherwise every unread chat is marked, regardless of any active filter.
  Future<void> markAllAsRead({Set<String>? chatGuids}) async {
    try {
      for (final entry in _logicalRegistry.entries) {
        final definition = LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
        if (definition == null) continue;
        final sources = _logicalSourceChats(definition);
        final presentation = _presentationChatForDefinition(definition);
        if (presentation == null) continue;
        final state = _synchronizeLogicalUnreadState(logicalId: entry.logicalId, sourceSnapshot: sources);
        final selected =
            chatGuids == null ||
            chatGuids.contains(conversationKeyFor(presentation)) ||
            sources.any((source) => chatGuids.contains(source.guid));
        if (selected && state?.ledger.hasUnread == true) {
          await markLogicalConversationRead(presentation);
        }
      }

      // Phase 1: instant UI update from in-memory state — no DB query needed
      final unreadStates = chatStates.values
          .where(
            (s) =>
                !isPotentialLogicalSource(s.chat) &&
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
    final items = List<Chat>.from(chatList.where(isConversationPinned));
    items.sort((a, b) => (conversationPinIndex(a) ?? 0).compareTo(conversationPinIndex(b) ?? 0));

    final item = items[oldIndex];

    // Remove the item at the old index, and re-add it at the newIndex
    // We dynamically subtract 1 from the new index depending on if the newIndex is > the oldIndex
    items.removeAt(oldIndex);
    items.insert(newIndex + (oldIndex < newIndex ? -1 : 0), item);

    // Route through the logical ledger for certified conversations. Ordinary
    // chats retain the existing database-backed setter behavior.
    items.forEachIndexed((i, chat) {
      unawaited(setChatPinIndex(chat, i).then((_) => _repositionChat(chat, immediate: true)));
    });
  }

  void removePinIndices() {
    final chatList = getSortedChats();
    // Create a snapshot to avoid concurrent modification during iteration
    final pinnedChats = List<Chat>.from(chatList.where((chat) => conversationPinIndex(chat) != null));
    for (final chat in pinnedChats) {
      unawaited(setChatPinIndex(chat, null).then((_) => _repositionChat(chat, immediate: true)));
    }
  }

  Future<void> updateShareTargets() async {
    if (Platform.isAndroid) {
      StartupTasks.waitForUI().then((_) async {
        // Create a snapshot to avoid concurrent modification during iteration
        final registry = _logicalRegistry;
        final physicalShortcutIds = <String>{};
        final logicalShortcutIds = <LogicalConversationId>{};
        final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
        final activeCandidateRefs = _logicalCandidateQuarantine
            .recordsAt(nowEpochMs: nowEpochMs)
            .where(
              (record) =>
                  logicalCandidatePresentationAdmission(phase: record.phase, admittedToActiveCertificate: false) ==
                  LogicalCandidatePresentationAdmission.suppressPhysical,
            )
            .map((record) => record.candidate)
            .toSet();
        _scheduleLogicalCandidateQuarantinePersistence(nowEpochMs);
        for (final state in chatStates.values) {
          if (activeCandidateRefs.contains(PhysicalConversationRef.fromStablePhysicalGuid(state.chat.guid))) {
            physicalShortcutIds.add(state.chat.guid);
          }
        }
        for (final entry in registry.entries) {
          final definition = LogicalConversationViewPolicy.certificateForLogicalId(entry.logicalId);
          if (definition == null) continue;
          physicalShortcutIds.addAll(_logicalSourceChats(definition).map((source) => source.guid));
          logicalShortcutIds.add(entry.logicalId);
        }
        await MethodChannelSvc.actions.removeShareTargets(
          candidateIds: LogicalPlatformCleanupPlan.shareTargetCandidates(physicalShortcutIds),
          protectedIds: LogicalPlatformCleanupPlan.protectedShareTargetKeys(logicalShortcutIds),
        );

        // Cleanup is registry-wide and intentionally runs before the visible
        // top-four snapshot. A certified or actively quarantined physical
        // shortcut must not survive merely because its logical presentation
        // is outside the current top four targets. Rejected/expired-visible
        // candidates are deliberately absent and may be recreated ordinarily.
        final chatList = getSortedChats();
        final chatSnapshot = chatList.where((e) => !isNullOrEmpty(e.displayName ?? e.chatIdentifier)).take(4).toList();
        for (Chat c in chatSnapshot) {
          await MethodChannelSvc.actions.pushShareTarget(
            title: c.getTitle(),
            guid: c.guid,
            conversationKey: conversationKeyFor(c),
            legacyPhysicalGuids: isApprovedLogicalSource(c)
                ? logicalSourceChatsFor(c).map((source) => source.guid).toList(growable: false)
                : const <String>[],
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
    final approvedSourceRows = LogicalConversationViewPolicy.approvedSourceRowIds;
    final query = Database.chats.query(Chat_.originalROWID.oneOf(approvedSourceRows.toList())).build();
    final existingCount = query.count();
    query.close();
    if (existingCount == approvedSourceRows.length) {
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

        final refreshedQuery = Database.chats.query(Chat_.originalROWID.oneOf(approvedSourceRows.toList())).build();
        final refreshedCount = refreshedQuery.count();
        refreshedQuery.close();
        if (refreshedCount == approvedSourceRows.length) {
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

  void _resetLogicalProjectionCursors(String logicalId) {
    final prefix = '$logicalId:';
    _logicalHydrationCursors.removeWhere((key, _) => key.startsWith(prefix));
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
    final definition = _logicalDefinitionForChat(chat);
    if (definition == null) return;
    final requiredDepth = offset + limit;
    for (final source in sources) {
      final authorityRevision = logicalProjectionAuthorityRevisionFor(source);
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
    await PrefsSvc.messaging.setLastOpenedChat(conversationKeyFor(chat));
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

    if (clearNotifications) {
      // Defer the observable update to avoid updating during build phase
      unawaited(
        Future<void>.microtask(() async {
          try {
            if (isLogicalConversation(chatState.chat)) {
              await markLogicalConversationRead(chatState.chat);
            } else {
              await setChatHasUnread(chatState.chat, false, force: true);
            }
          } catch (error, trace) {
            Logger.warn('View-entry read acknowledgement failed', error: error, trace: trace, tag: 'LogicalUnread');
          }
        }),
      );
    }

    if (save) {
      unawaited(PrefsSvc.messaging.setLastOpenedChat(conversationKeyFor(chat)));
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
    if (isPotentialLogicalSource(chat)) return;

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
    if (isPotentialLogicalSource(chat)) return;

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
    if (isPotentialLogicalSource(chat)) return;
    await ChatInterface.unDeleteChat(chatData: chat.toMap());
  }

  /// Clears only an ordinary physical transcript. Protected source records are
  /// observational provenance and are never rewritten through this UI action.
  bool clearChatTranscript(Chat chat) {
    if (kIsWeb || isPotentialLogicalSource(chat)) return false;
    chat.clearTranscript();
    EventDispatcherSvc.emit('refresh-messagebloc', {'chatGuid': chat.guid});
    return true;
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
    if (isApprovedLogicalSource(chat)) {
      final maxPinIndex = allChats
          .where(isConversationPinned)
          .map(conversationPinIndex)
          .whereType<int>()
          .fold<int>(-1, (maximum, index) => index > maximum ? index : maximum);
      await _mutateLogicalSettings(
        chat,
        kind: 'pin',
        value: value,
        isPinned: value,
        pinIndex: value ? maxPinIndex + 1 : null,
        clearPinIndex: !value,
      );
      return;
    }
    if (isPotentialLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.isPinned.value == value) return;

    // Update DB
    await _toggleChatPin(chat, value);

    // Update state if available
    state?.updateIsPinnedInternal(value);
  }

  /// Set chat pin index
  Future<void> setChatPinIndex(Chat chat, int? value) async {
    if (isApprovedLogicalSource(chat)) {
      await _mutateLogicalSettings(
        chat,
        kind: 'pin-index',
        value: value,
        isPinned: value != null,
        pinIndex: value,
        clearPinIndex: value == null,
      );
      return;
    }
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isApprovedLogicalSource(chat)) {
      await _mutateLogicalSettings(chat, kind: 'mute', value: isMuted, isMuted: isMuted);
      return;
    }
    if (isPotentialLogicalSource(chat)) return;
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
    if (isApprovedLogicalSource(chat)) {
      await _mutateLogicalSettings(chat, kind: 'archive', value: value, isArchived: value);
      return;
    }
    if (isPotentialLogicalSource(chat)) return;
    final state = getChatState(chat.guid);

    if (state != null && state.isArchived.value == value) return;

    // Update DB
    await _toggleChatArchive(chat, value);

    // Update state if available
    state?.updateArchivedInternal(value);
  }

  /// Set chat auto send read receipts
  Future<void> setChatAutoSendReadReceipts(Chat chat, bool? value) async {
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    if (isPotentialLogicalSource(chat)) return;
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
    _invalidateKnownLogicalDraftPreviews();
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
    _logicalUnreadStates.clear();
    _logicalMembershipAvailability.clear();
    logicalMarkReadOutcome.value = null;
    logicalReadSyncPending.value = false;
    _logicalCandidateReconciliationTimer?.cancel();
    _logicalCandidateReconciliationTimer = null;
    _logicalCandidateReconciliationGeneration += 1;

    countSub?.cancel();
    if (reinitWatchers) {
      initDbWatchers();
    }
  }
}
