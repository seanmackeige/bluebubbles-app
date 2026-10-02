import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:crypto/crypto.dart';

const logicalConversationSettingsLedgerSchema = 'LOGICAL_CONVERSATION_SETTINGS_LEDGER_V1';
const _maxAppliedLogicalSettingOperations = 64;

bool migrateLogicalAllMuteFromPhysicalProvenance(String? muteType) => muteType == 'mute';

/// Durable human-intent migration may read only the certificate's exact
/// presentation member. A sibling is useful as a transient display fallback,
/// but is never provenance for local settings.
T? exactLogicalSettingsMigrationPresentation<T>(
  Iterable<T> sources, {
  required int presentationSourceRowId,
  required int? Function(T source) sourceRowIdOf,
}) {
  final matches = sources.where((source) => sourceRowIdOf(source) == presentationSourceRowId).toList();
  return matches.length == 1 ? matches.single : null;
}

bool shouldPreserveSpecializedPhysicalMute(String? muteType) => muteType != null && muteType != 'mute';

bool shouldMuteLogicalConversationNotification({
  required bool logicalAllMuted,
  required bool unknownSenderFiltered,
  required String globalTextDetection,
  required String? messageText,
  required bool notifyReactions,
  required bool isReaction,
}) {
  if (unknownSenderFiltered) return true;
  if (globalTextDetection.isNotEmpty) {
    for (final term in globalTextDetection.split(',')) {
      if (messageText?.toLowerCase().contains(term.toLowerCase()) ?? false) return false;
    }
    return true;
  }
  if (logicalAllMuted) return true;
  return !notifyReactions && isReaction;
}

class LogicalConversationSettings {
  LogicalConversationSettings({
    required this.logicalId,
    this.revision = 0,
    this.isPinned = false,
    this.pinIndex,
    this.isArchived = false,
    this.isMuted = false,
    Set<int> customGroupIds = const <int>{},
    List<String> appliedOperationIds = const <String>[],
    this.migratedFromPhysicalProvenance = false,
  }) : customGroupIds = Set<int>.unmodifiable(customGroupIds),
       appliedOperationIds = List<String>.unmodifiable(appliedOperationIds) {
    if (!logicalId.isCertified) throw ArgumentError('Logical settings require a certified conversation identity');
    if (revision < 0 || pinIndex != null && pinIndex! < 0 || customGroupIds.any((id) => id <= 0)) {
      throw ArgumentError('Logical settings contain invalid local presentation values');
    }
    if (!isPinned && pinIndex != null) throw ArgumentError('An unpinned conversation cannot retain a pin index');
    if (appliedOperationIds.length > _maxAppliedLogicalSettingOperations ||
        appliedOperationIds.any((id) => id.isEmpty || id.length > 256) ||
        appliedOperationIds.toSet().length != appliedOperationIds.length) {
      throw ArgumentError('Logical settings operation history is invalid');
    }
  }

  factory LogicalConversationSettings.fromJson(Map<String, dynamic> json) {
    final rawGroups = json['customGroupIds'];
    final rawOperations = json['appliedOperationIds'];
    if (rawGroups is! List || rawGroups.any((value) => value is! int)) {
      throw const FormatException('Invalid logical settings custom groups');
    }
    if (rawOperations is! List || rawOperations.any((value) => value is! String)) {
      throw const FormatException('Invalid logical settings operation history');
    }
    return LogicalConversationSettings(
      logicalId: LogicalConversationId.parse(json['logicalId'] as String),
      revision: json['revision'] as int,
      isPinned: json['isPinned'] as bool,
      pinIndex: json['pinIndex'] as int?,
      isArchived: json['isArchived'] as bool,
      isMuted: json['isMuted'] as bool,
      customGroupIds: rawGroups.cast<int>().toSet(),
      appliedOperationIds: rawOperations.cast<String>(),
      migratedFromPhysicalProvenance: json['migratedFromPhysicalProvenance'] as bool? ?? false,
    );
  }

  final LogicalConversationId logicalId;
  final int revision;
  final bool isPinned;
  final int? pinIndex;
  final bool isArchived;
  final bool isMuted;
  final Set<int> customGroupIds;
  final List<String> appliedOperationIds;
  final bool migratedFromPhysicalProvenance;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'logicalId': logicalId.value,
    'revision': revision,
    'isPinned': isPinned,
    'pinIndex': pinIndex,
    'isArchived': isArchived,
    'isMuted': isMuted,
    'customGroupIds': customGroupIds.toList()..sort(),
    'appliedOperationIds': appliedOperationIds,
    'migratedFromPhysicalProvenance': migratedFromPhysicalProvenance,
  };
}

class LogicalConversationSettingsMutation {
  const LogicalConversationSettingsMutation({
    required this.operationId,
    required this.expectedRevision,
    this.isPinned,
    this.pinIndex,
    this.clearPinIndex = false,
    this.isArchived,
    this.isMuted,
    this.customGroupIds,
  });

  final String operationId;
  final int expectedRevision;
  final bool? isPinned;
  final int? pinIndex;
  final bool clearPinIndex;
  final bool? isArchived;
  final bool? isMuted;
  final Set<int>? customGroupIds;
}

class LogicalConversationSettingsApplyResult {
  const LogicalConversationSettingsApplyResult({
    required this.settings,
    required this.applied,
    required this.duplicate,
    required this.revisionConflict,
  });

  final LogicalConversationSettings settings;
  final bool applied;
  final bool duplicate;
  final bool revisionConflict;
}

class LogicalConversationSettingsLedger {
  LogicalConversationSettingsLedger._(Map<String, LogicalConversationSettings> entries, {required this.isCorrupt})
    : _entries = Map<String, LogicalConversationSettings>.from(entries);

  factory LogicalConversationSettingsLedger.empty() =>
      LogicalConversationSettingsLedger._(const <String, LogicalConversationSettings>{}, isCorrupt: false);

  factory LogicalConversationSettingsLedger.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalConversationSettingsLedgerSchema || json['entries'] is! List) {
      throw const FormatException('Unsupported logical settings ledger');
    }
    final entries = <String, LogicalConversationSettings>{};
    for (final raw in json['entries'] as List) {
      if (raw is! Map) throw const FormatException('Invalid logical settings entry');
      final settings = LogicalConversationSettings.fromJson(raw.cast<String, dynamic>());
      if (entries.putIfAbsent(settings.logicalId.value, () => settings) != settings) {
        throw const FormatException('Duplicate logical settings identity');
      }
    }
    return LogicalConversationSettingsLedger._(entries, isCorrupt: false);
  }

  factory LogicalConversationSettingsLedger.decode(String? raw) {
    if (raw == null) return LogicalConversationSettingsLedger.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Invalid logical settings envelope');
      return LogicalConversationSettingsLedger.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return LogicalConversationSettingsLedger._(const <String, LogicalConversationSettings>{}, isCorrupt: true);
    }
  }

  final Map<String, LogicalConversationSettings> _entries;
  final bool isCorrupt;

  LogicalConversationSettings? forId(LogicalConversationId logicalId) => _entries[logicalId.value];

  bool migrateIfAbsent(LogicalConversationSettings settings) {
    if (isCorrupt || _entries.containsKey(settings.logicalId.value)) return false;
    _entries[settings.logicalId.value] = settings;
    return true;
  }

  LogicalConversationSettingsApplyResult apply(
    LogicalConversationId logicalId,
    LogicalConversationSettingsMutation mutation,
  ) {
    final current = _entries[logicalId.value] ?? LogicalConversationSettings(logicalId: logicalId);
    if (isCorrupt) {
      return LogicalConversationSettingsApplyResult(
        settings: current,
        applied: false,
        duplicate: false,
        revisionConflict: true,
      );
    }
    if (current.appliedOperationIds.contains(mutation.operationId)) {
      return LogicalConversationSettingsApplyResult(
        settings: current,
        applied: false,
        duplicate: true,
        revisionConflict: false,
      );
    }
    if (mutation.operationId.isEmpty ||
        mutation.operationId.length > 256 ||
        mutation.expectedRevision != current.revision) {
      return LogicalConversationSettingsApplyResult(
        settings: current,
        applied: false,
        duplicate: false,
        revisionConflict: true,
      );
    }

    final nextPinned = mutation.isPinned ?? current.isPinned;
    final nextPinIndex = nextPinned ? (mutation.clearPinIndex ? null : mutation.pinIndex ?? current.pinIndex) : null;
    final nextOperations = <String>[...current.appliedOperationIds, mutation.operationId];
    if (nextOperations.length > _maxAppliedLogicalSettingOperations) {
      nextOperations.removeRange(0, nextOperations.length - _maxAppliedLogicalSettingOperations);
    }
    final next = LogicalConversationSettings(
      logicalId: logicalId,
      revision: current.revision + 1,
      isPinned: nextPinned,
      pinIndex: nextPinIndex,
      isArchived: mutation.isArchived ?? current.isArchived,
      isMuted: mutation.isMuted ?? current.isMuted,
      customGroupIds: mutation.customGroupIds ?? current.customGroupIds,
      appliedOperationIds: nextOperations,
      migratedFromPhysicalProvenance: current.migratedFromPhysicalProvenance,
    );
    _entries[logicalId.value] = next;
    return LogicalConversationSettingsApplyResult(
      settings: next,
      applied: true,
      duplicate: false,
      revisionConflict: false,
    );
  }

  String operationId({
    required LogicalConversationId logicalId,
    required int expectedRevision,
    required String kind,
    required Object? value,
  }) {
    final material = jsonEncode(<String, dynamic>{
      'schema': logicalConversationSettingsLedgerSchema,
      'logicalId': logicalId.value,
      'expectedRevision': expectedRevision,
      'kind': kind,
      'value': value,
    });
    return sha256.convert(utf8.encode(material)).toString();
  }

  Map<String, dynamic> toJson() {
    final entries = _entries.values.toList()..sort((a, b) => a.logicalId.compareTo(b.logicalId));
    return <String, dynamic>{
      'schema': logicalConversationSettingsLedgerSchema,
      'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
    };
  }

  String encode() => jsonEncode(toJson());
}

class LogicalConversationSettingsCommitResult {
  const LogicalConversationSettingsCommitResult({
    required this.ledger,
    required this.applyResult,
    required this.committed,
    this.failure,
    this.failureTrace,
  });

  final LogicalConversationSettingsLedger ledger;
  final LogicalConversationSettingsApplyResult applyResult;
  final bool committed;
  final Object? failure;
  final StackTrace? failureTrace;
}

/// Applies a local human-intent setting transactionally. The caller's ledger
/// is never mutated. A newly applied value is published only after [persist]
/// durably accepts its deterministic encoding; duplicate operations already
/// present in the durable ledger remain successful and require no rewrite.
Future<LogicalConversationSettingsCommitResult> commitLogicalConversationSettingsMutation({
  required LogicalConversationSettingsLedger current,
  required LogicalConversationId logicalId,
  required LogicalConversationSettingsMutation mutation,
  required Future<void> Function(String encodedLedger) persist,
}) async {
  final working = LogicalConversationSettingsLedger.decode(current.encode());
  final result = working.apply(logicalId, mutation);
  if (result.duplicate) {
    return LogicalConversationSettingsCommitResult(ledger: current, applyResult: result, committed: true);
  }
  if (!result.applied) {
    return LogicalConversationSettingsCommitResult(ledger: current, applyResult: result, committed: false);
  }
  try {
    await persist(working.encode());
    return LogicalConversationSettingsCommitResult(ledger: working, applyResult: result, committed: true);
  } catch (error, trace) {
    return LogicalConversationSettingsCommitResult(
      ledger: current,
      applyResult: result,
      committed: false,
      failure: error,
      failureTrace: trace,
    );
  }
}

class LogicalConversationSettingsMigrationCommitResult {
  const LogicalConversationSettingsMigrationCommitResult({
    required this.ledger,
    required this.committed,
    required this.changed,
    this.failure,
    this.failureTrace,
  });

  final LogicalConversationSettingsLedger ledger;
  final bool committed;
  final bool changed;
  final Object? failure;
  final StackTrace? failureTrace;
}

/// Copies, persists, then publishes one-time provider-provenance migrations.
/// A failed durable write leaves the caller's ledger byte-for-byte unchanged.
Future<LogicalConversationSettingsMigrationCommitResult> commitLogicalConversationSettingsMigrations({
  required LogicalConversationSettingsLedger current,
  required Iterable<LogicalConversationSettings> migrations,
  required Future<void> Function(String encodedLedger) persist,
}) async {
  if (current.isCorrupt) {
    return LogicalConversationSettingsMigrationCommitResult(ledger: current, committed: false, changed: false);
  }
  final working = LogicalConversationSettingsLedger.decode(current.encode());
  var changed = false;
  for (final migration in migrations) {
    changed = working.migrateIfAbsent(migration) || changed;
  }
  if (!changed) {
    return LogicalConversationSettingsMigrationCommitResult(ledger: current, committed: true, changed: false);
  }
  try {
    await persist(working.encode());
    return LogicalConversationSettingsMigrationCommitResult(ledger: working, committed: true, changed: true);
  } catch (error, trace) {
    return LogicalConversationSettingsMigrationCommitResult(
      ledger: current,
      committed: false,
      changed: false,
      failure: error,
      failureTrace: trace,
    );
  }
}

/// Serializes the complete read, clone, persist, and publish transaction.
/// Errors are delivered to the originating caller without poisoning later
/// mutations in the same process.
class LogicalConversationSettingsTransactionQueue {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        result.complete(await operation());
      } catch (error, trace) {
        result.completeError(error, trace);
      }
    });
    return result.future;
  }
}

Set<int> applyLogicalCustomGroupDelta({required Iterable<int> current, required int groupId, required bool included}) {
  if (groupId <= 0) throw ArgumentError.value(groupId, 'groupId');
  final next = current.toSet();
  included ? next.add(groupId) : next.remove(groupId);
  return next;
}
