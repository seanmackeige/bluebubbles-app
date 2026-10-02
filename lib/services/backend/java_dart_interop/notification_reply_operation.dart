// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

@pragma('vm:entry-point')
const notificationReplyOperationContract = 'LOGICAL_NOTIFICATION_REPLY_OPERATION_V2_DURABLE_BOUNDARY';
const notificationReplyOperationJournalSchema = 2;
const notificationReplyOperationJournalLegacySchema = 1;
const notificationReplyOperationJournalMaxActiveEntries = 256;

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

String _fingerprint(String label, String value) => sha256.convert(utf8.encode('$label\u0000$value')).toString();

String notificationReplyProcessFingerprint(int processId) =>
    _fingerprint('notification-reply-process-v1', processId.toString());

enum NotificationReplyOperationState { reserved, executionStarted, terminal, preExecutionRejected, outcomeAmbiguous }

extension NotificationReplyOperationStateWire on NotificationReplyOperationState {
  String get wireName => switch (this) {
    NotificationReplyOperationState.reserved => 'reserved',
    NotificationReplyOperationState.executionStarted => 'execution_started',
    NotificationReplyOperationState.terminal => 'terminal',
    NotificationReplyOperationState.preExecutionRejected => 'pre_execution_rejected',
    NotificationReplyOperationState.outcomeAmbiguous => 'outcome_ambiguous',
  };

  static NotificationReplyOperationState parse(String value) => switch (value) {
    'reserved' => NotificationReplyOperationState.reserved,
    'execution_started' => NotificationReplyOperationState.executionStarted,
    'terminal' => NotificationReplyOperationState.terminal,
    'pre_execution_rejected' => NotificationReplyOperationState.preExecutionRejected,
    'outcome_ambiguous' => NotificationReplyOperationState.outcomeAmbiguous,
    _ => throw const FormatException('NOTIFICATION_REPLY_OPERATION_STATE_INVALID'),
  };
}

class NotificationReplyOperationIdentity {
  const NotificationReplyOperationIdentity._({
    required this.operationId,
    required this.conversationKeySha256,
    required this.sourceChatGuidSha256,
    required this.messageGuidSha256,
    required this.textSha256,
  });

  factory NotificationReplyOperationIdentity.fromExactInput({
    required String conversationKey,
    required String sourceChatGuid,
    required String messageGuid,
    required String text,
  }) {
    if (conversationKey.isEmpty || sourceChatGuid.isEmpty || messageGuid.isEmpty || text.isEmpty) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_IDENTITY_INCOMPLETE');
    }
    final conversation = _fingerprint('conversation-key', conversationKey);
    final source = _fingerprint('source-chat-guid', sourceChatGuid);
    final message = _fingerprint('message-guid', messageGuid);
    final payload = _fingerprint('reply-text', text);
    return NotificationReplyOperationIdentity._fromFingerprints(
      conversationKeySha256: conversation,
      sourceChatGuidSha256: source,
      messageGuidSha256: message,
      textSha256: payload,
    );
  }

  factory NotificationReplyOperationIdentity._fromFingerprints({
    required String conversationKeySha256,
    required String sourceChatGuidSha256,
    required String messageGuidSha256,
    required String textSha256,
  }) {
    for (final value in <String>[conversationKeySha256, sourceChatGuidSha256, messageGuidSha256, textSha256]) {
      if (!_sha256Pattern.hasMatch(value)) {
        throw const FormatException('NOTIFICATION_REPLY_OPERATION_FINGERPRINT_INVALID');
      }
    }
    final operationId = sha256
        .convert(
          utf8.encode(
            'notification-reply-operation-v1\u0000$conversationKeySha256\u0000$sourceChatGuidSha256'
            '\u0000$messageGuidSha256\u0000$textSha256',
          ),
        )
        .toString();
    return NotificationReplyOperationIdentity._(
      operationId: operationId,
      conversationKeySha256: conversationKeySha256,
      sourceChatGuidSha256: sourceChatGuidSha256,
      messageGuidSha256: messageGuidSha256,
      textSha256: textSha256,
    );
  }

  factory NotificationReplyOperationIdentity.fromJson(Map<String, dynamic> json) {
    final identity = NotificationReplyOperationIdentity._fromFingerprints(
      conversationKeySha256: json['conversation_key_sha256'] as String? ?? '',
      sourceChatGuidSha256: json['source_chat_guid_sha256'] as String? ?? '',
      messageGuidSha256: json['message_guid_sha256'] as String? ?? '',
      textSha256: json['text_sha256'] as String? ?? '',
    );
    if (json['operation_id'] != identity.operationId) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_ID_MISMATCH');
    }
    return identity;
  }

  final String operationId;
  final String conversationKeySha256;
  final String sourceChatGuidSha256;
  final String messageGuidSha256;
  final String textSha256;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'operation_id': operationId,
    'conversation_key_sha256': conversationKeySha256,
    'source_chat_guid_sha256': sourceChatGuidSha256,
    'message_guid_sha256': messageGuidSha256,
    'text_sha256': textSha256,
  };

  @override
  bool operator ==(Object other) => other is NotificationReplyOperationIdentity && other.operationId == operationId;

  @override
  int get hashCode => operationId.hashCode;
}

String notificationReplyTempMessageGuid(NotificationReplyOperationIdentity identity) {
  final value = StringBuffer('temp-notification-reply-')..write(identity.operationId);
  return value.toString();
}

enum NotificationReplyPreparedRollbackStep { persistedMessage, presentationMessage, latestMessage }

class NotificationReplyPreparedRollbackResult {
  const NotificationReplyPreparedRollbackResult(this.failedSteps);

  final Set<NotificationReplyPreparedRollbackStep> failedSteps;

  bool get isComplete => failedSteps.isEmpty;
}

/// Best-effort local rollback for a message prepared before provider dispatch.
///
/// Every step is attempted even if an earlier cleanup fails. Callers retain a
/// deterministic temp GUID as a second barrier, so a retry reuses rather than
/// duplicates a row when local storage is temporarily unavailable.
class NotificationReplyPreparedMessageRollback {
  const NotificationReplyPreparedMessageRollback._();

  static Future<NotificationReplyPreparedRollbackResult> run({
    required Future<void> Function() deletePersistedMessage,
    required Future<void> Function() removePresentationMessage,
    required Future<void> Function() restoreLatestMessage,
  }) async {
    final failed = <NotificationReplyPreparedRollbackStep>{};
    for (final entry in <MapEntry<NotificationReplyPreparedRollbackStep, Future<void> Function()>>[
      MapEntry(NotificationReplyPreparedRollbackStep.persistedMessage, deletePersistedMessage),
      MapEntry(NotificationReplyPreparedRollbackStep.presentationMessage, removePresentationMessage),
      MapEntry(NotificationReplyPreparedRollbackStep.latestMessage, restoreLatestMessage),
    ]) {
      try {
        await entry.value();
      } catch (_) {
        failed.add(entry.key);
      }
    }
    return NotificationReplyPreparedRollbackResult(Set<NotificationReplyPreparedRollbackStep>.unmodifiable(failed));
  }
}

/// Couples the last pre-provider admission step to cleanup of its locally
/// prepared message.
///
/// The original admission error is preserved even when cleanup is only
/// best-effort. A caller must invoke its provider only after this returns.
class NotificationReplyPreparedDispatchAdmission {
  const NotificationReplyPreparedDispatchAdmission._();

  static Future<void> run({
    required Future<void> Function() admit,
    required Future<void> Function() rollbackPreparedMessage,
  }) async {
    try {
      await admit();
    } catch (error, stack) {
      try {
        await rollbackPreparedMessage();
      } catch (_) {
        // Preserve the admission failure. The deterministic temp GUID remains
        // the retry dedupe barrier when local cleanup itself is unavailable.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }
}

class NotificationReplyOperationRecord {
  const NotificationReplyOperationRecord({
    required this.identity,
    required this.state,
    required this.attemptId,
    required this.processFingerprint,
    required this.revision,
  });

  factory NotificationReplyOperationRecord.fromJson(Map<String, dynamic> json) {
    final attemptId = json['attempt_id'];
    final processFingerprint = json['process_fingerprint'];
    final revision = json['revision'];
    if (attemptId is! String ||
        !_sha256Pattern.hasMatch(attemptId) ||
        processFingerprint is! String ||
        !_sha256Pattern.hasMatch(processFingerprint) ||
        revision is! int ||
        revision <= 0) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_RECORD_INVALID');
    }
    return NotificationReplyOperationRecord(
      identity: NotificationReplyOperationIdentity.fromJson(json),
      state: NotificationReplyOperationStateWire.parse(json['state'] as String? ?? ''),
      attemptId: attemptId,
      processFingerprint: processFingerprint,
      revision: revision,
    );
  }

  final NotificationReplyOperationIdentity identity;
  final NotificationReplyOperationState state;
  final String attemptId;
  final String processFingerprint;
  final int revision;

  NotificationReplyOperationRecord transition(
    NotificationReplyOperationState next, {
    String? nextAttemptId,
    String? nextProcessFingerprint,
  }) => NotificationReplyOperationRecord(
    identity: identity,
    state: next,
    attemptId: nextAttemptId ?? attemptId,
    processFingerprint: nextProcessFingerprint ?? processFingerprint,
    revision: revision + 1,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...identity.toJson(),
    'state': state.wireName,
    'attempt_id': attemptId,
    'process_fingerprint': processFingerprint,
    'revision': revision,
  };
}

enum NotificationReplyBeginDisposition {
  accepted,
  duplicateInFlight,
  alreadyTerminal,
  recoverablePreExecutionReservation,
  ambiguousPriorExecution,
}

class NotificationReplyBeginDecision {
  const NotificationReplyBeginDecision({required this.journal, required this.disposition, required this.record});

  final NotificationReplyOperationJournal journal;
  final NotificationReplyBeginDisposition disposition;
  final NotificationReplyOperationRecord record;
}

class NotificationReplyOperationJournal {
  const NotificationReplyOperationJournal._(this._records, this._blockingTombstones);

  factory NotificationReplyOperationJournal.empty() => const NotificationReplyOperationJournal._(
    <String, NotificationReplyOperationRecord>{},
    <String, NotificationReplyOperationState>{},
  );

  factory NotificationReplyOperationJournal.decode(String? raw) {
    if (raw == null) return NotificationReplyOperationJournal.empty();
    if (raw.isEmpty) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_EMPTY');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_INVALID_JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_SCHEMA_INVALID');
    }
    final schema = decoded['schema'];
    if (schema != notificationReplyOperationJournalSchema && schema != notificationReplyOperationJournalLegacySchema) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_SCHEMA_INVALID');
    }
    final rawRecords = decoded['records'];
    if (rawRecords is! List || rawRecords.length > notificationReplyOperationJournalMaxActiveEntries) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_RECORDS_INVALID');
    }

    final records = <String, NotificationReplyOperationRecord>{};
    final tombstones = <String, NotificationReplyOperationState>{};
    for (final rawRecord in rawRecords) {
      if (rawRecord is! Map) {
        throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_RECORD_INVALID');
      }
      final record = NotificationReplyOperationRecord.fromJson(Map<String, dynamic>.from(rawRecord));
      final operationId = record.identity.operationId;
      if (records.containsKey(operationId) || tombstones.containsKey(operationId)) {
        throw const FormatException('NOTIFICATION_REPLY_OPERATION_JOURNAL_DUPLICATE');
      }
      if (_isBlockingState(record.state)) {
        tombstones[operationId] = record.state;
      } else {
        records[operationId] = record;
      }
    }

    final rawTombstones = schema == notificationReplyOperationJournalSchema
        ? decoded['blocking_tombstones']
        : const <Object?>[];
    if (rawTombstones is! List) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_TOMBSTONES_INVALID');
    }
    for (final rawTombstone in rawTombstones) {
      if (rawTombstone is! Map) {
        throw const FormatException('NOTIFICATION_REPLY_OPERATION_TOMBSTONE_INVALID');
      }
      final operationId = rawTombstone['operation_id'];
      final state = NotificationReplyOperationStateWire.parse(rawTombstone['state'] as String? ?? '');
      if (operationId is! String ||
          !_sha256Pattern.hasMatch(operationId) ||
          !_isBlockingState(state) ||
          records.containsKey(operationId) ||
          tombstones.containsKey(operationId)) {
        throw const FormatException('NOTIFICATION_REPLY_OPERATION_TOMBSTONE_INVALID');
      }
      tombstones[operationId] = state;
    }

    return NotificationReplyOperationJournal._(
      Map<String, NotificationReplyOperationRecord>.unmodifiable(records),
      Map<String, NotificationReplyOperationState>.unmodifiable(tombstones),
    );
  }

  final Map<String, NotificationReplyOperationRecord> _records;
  final Map<String, NotificationReplyOperationState> _blockingTombstones;

  int get length => _records.length + _blockingTombstones.length;
  int get activeLength => _records.length;
  int get blockingTombstoneLength => _blockingTombstones.length;

  NotificationReplyOperationRecord? recordFor(NotificationReplyOperationIdentity identity) {
    final active = _records[identity.operationId];
    if (active != null) return active;
    final state = _blockingTombstones[identity.operationId];
    if (state == null) return null;
    return NotificationReplyOperationRecord(
      identity: identity,
      state: state,
      attemptId: identity.operationId,
      processFingerprint: identity.operationId,
      revision: 1,
    );
  }

  String encode() {
    final ordered = _records.values.toList(growable: false)
      ..sort((left, right) => left.identity.operationId.compareTo(right.identity.operationId));
    final orderedTombstones = _blockingTombstones.entries.toList(growable: false)
      ..sort((left, right) => left.key.compareTo(right.key));
    return jsonEncode(<String, dynamic>{
      'schema': notificationReplyOperationJournalSchema,
      'records': ordered.map((record) => record.toJson()).toList(growable: false),
      'blocking_tombstones': orderedTombstones
          .map((entry) => <String, dynamic>{'operation_id': entry.key, 'state': entry.value.wireName})
          .toList(growable: false),
    });
  }

  NotificationReplyBeginDecision begin({
    required NotificationReplyOperationIdentity identity,
    required String attemptId,
    required String processFingerprint,
  }) {
    if (!_sha256Pattern.hasMatch(attemptId) || !_sha256Pattern.hasMatch(processFingerprint)) {
      throw const FormatException('NOTIFICATION_REPLY_OPERATION_ATTEMPT_INVALID');
    }

    final blockingState = _blockingTombstones[identity.operationId];
    if (blockingState != null) {
      return NotificationReplyBeginDecision(
        journal: this,
        disposition: blockingState == NotificationReplyOperationState.terminal
            ? NotificationReplyBeginDisposition.alreadyTerminal
            : NotificationReplyBeginDisposition.ambiguousPriorExecution,
        record: recordFor(identity)!,
      );
    }

    final existing = _records[identity.operationId];
    if (existing == null) {
      var target = this;
      if (_records.length >= notificationReplyOperationJournalMaxActiveEntries) {
        final evictable =
            _records.values
                .where((record) => record.state == NotificationReplyOperationState.preExecutionRejected)
                .toList(growable: false)
              ..sort((left, right) => left.identity.operationId.compareTo(right.identity.operationId));
        if (evictable.isEmpty) {
          throw StateError('NOTIFICATION_REPLY_OPERATION_JOURNAL_CAPACITY');
        }
        // A pre-execution rejection proves the provider boundary was never
        // crossed. Its WorkManager payload retains the exact human intent, so
        // dropping only this retryable record cannot permit a duplicate send.
        target = _removeActive(evictable.first.identity.operationId);
      }
      final record = NotificationReplyOperationRecord(
        identity: identity,
        state: NotificationReplyOperationState.reserved,
        attemptId: attemptId,
        processFingerprint: processFingerprint,
        revision: 1,
      );
      return NotificationReplyBeginDecision(
        journal: target._replace(record),
        disposition: NotificationReplyBeginDisposition.accepted,
        record: record,
      );
    }
    if (existing.identity != identity) {
      throw StateError('NOTIFICATION_REPLY_OPERATION_IDENTITY_COLLISION');
    }
    switch (existing.state) {
      case NotificationReplyOperationState.preExecutionRejected:
        final record = existing.transition(
          NotificationReplyOperationState.reserved,
          nextAttemptId: attemptId,
          nextProcessFingerprint: processFingerprint,
        );
        return NotificationReplyBeginDecision(
          journal: _replace(record),
          disposition: NotificationReplyBeginDisposition.accepted,
          record: record,
        );
      case NotificationReplyOperationState.reserved:
        return NotificationReplyBeginDecision(
          journal: this,
          disposition: existing.processFingerprint == processFingerprint
              ? NotificationReplyBeginDisposition.duplicateInFlight
              : NotificationReplyBeginDisposition.recoverablePreExecutionReservation,
          record: existing,
        );
      case NotificationReplyOperationState.executionStarted:
        return NotificationReplyBeginDecision(
          journal: this,
          disposition: existing.processFingerprint == processFingerprint
              ? NotificationReplyBeginDisposition.duplicateInFlight
              : NotificationReplyBeginDisposition.ambiguousPriorExecution,
          record: existing,
        );
      case NotificationReplyOperationState.terminal:
        throw StateError('NOTIFICATION_REPLY_TERMINAL_RECORD_NOT_COMPACTED');
      case NotificationReplyOperationState.outcomeAmbiguous:
        throw StateError('NOTIFICATION_REPLY_AMBIGUOUS_RECORD_NOT_COMPACTED');
    }
  }

  NotificationReplyOperationJournal transition({
    required NotificationReplyOperationIdentity identity,
    required String attemptId,
    required NotificationReplyOperationState from,
    required NotificationReplyOperationState to,
  }) {
    final existing = _records[identity.operationId];
    if (existing == null ||
        existing.identity != identity ||
        existing.attemptId != attemptId ||
        existing.state != from) {
      throw StateError('NOTIFICATION_REPLY_OPERATION_TRANSITION_CONTRADICTION');
    }
    final allowed = switch ((from, to)) {
      (NotificationReplyOperationState.reserved, NotificationReplyOperationState.executionStarted) => true,
      (NotificationReplyOperationState.reserved, NotificationReplyOperationState.preExecutionRejected) => true,
      (NotificationReplyOperationState.executionStarted, NotificationReplyOperationState.terminal) => true,
      (NotificationReplyOperationState.executionStarted, NotificationReplyOperationState.outcomeAmbiguous) => true,
      _ => false,
    };
    if (!allowed) {
      throw StateError('NOTIFICATION_REPLY_OPERATION_TRANSITION_INVALID');
    }
    return _replace(existing.transition(to));
  }

  NotificationReplyOperationJournal _replace(NotificationReplyOperationRecord record) {
    final operationId = record.identity.operationId;
    final nextRecords = Map<String, NotificationReplyOperationRecord>.from(_records);
    final nextTombstones = Map<String, NotificationReplyOperationState>.from(_blockingTombstones);
    if (_isBlockingState(record.state)) {
      nextRecords.remove(operationId);
      final existing = nextTombstones[operationId];
      if (existing != null && existing != record.state) {
        throw StateError('NOTIFICATION_REPLY_TOMBSTONE_CONTRADICTION');
      }
      nextTombstones[operationId] = record.state;
    } else {
      if (nextTombstones.containsKey(operationId)) {
        throw StateError('NOTIFICATION_REPLY_TOMBSTONE_REOPEN_BLOCKED');
      }
      nextRecords[operationId] = record;
    }
    return NotificationReplyOperationJournal._(
      Map<String, NotificationReplyOperationRecord>.unmodifiable(nextRecords),
      Map<String, NotificationReplyOperationState>.unmodifiable(nextTombstones),
    );
  }

  NotificationReplyOperationJournal _removeActive(String operationId) {
    final nextRecords = Map<String, NotificationReplyOperationRecord>.from(_records)..remove(operationId);
    return NotificationReplyOperationJournal._(
      Map<String, NotificationReplyOperationRecord>.unmodifiable(nextRecords),
      _blockingTombstones,
    );
  }

  static bool _isBlockingState(NotificationReplyOperationState state) =>
      state == NotificationReplyOperationState.terminal || state == NotificationReplyOperationState.outcomeAmbiguous;
}

enum NotificationReplyExecutionDisposition {
  terminal,
  alreadyTerminal,
  preExecutionRejected,
  duplicateInFlight,
  outcomeAmbiguous,
  journalUnavailable,
}

class NotificationReplyExecutionResult {
  const NotificationReplyExecutionResult(this.disposition);

  final NotificationReplyExecutionDisposition disposition;

  bool get shouldCommitWorker =>
      disposition == NotificationReplyExecutionDisposition.terminal ||
      disposition == NotificationReplyExecutionDisposition.alreadyTerminal;
}

typedef NotificationReplyJournalLoader = Future<String?> Function();
typedef NotificationReplyJournalSaver = Future<void> Function(String value);
typedef NotificationReplyDispatch = Future<void> Function(Future<void> Function() markExecutionStarted);

class NotificationReplyOperationCoordinator {
  NotificationReplyOperationCoordinator({
    required this.processFingerprint,
    required NotificationReplyJournalLoader load,
    required NotificationReplyJournalSaver save,
    String Function(String operationId, int ordinal)? attemptIdFactory,
  }) : _load = load,
       _save = save,
       _attemptIdFactory = attemptIdFactory;

  final String processFingerprint;
  final NotificationReplyJournalLoader _load;
  final NotificationReplyJournalSaver _save;
  final String Function(String operationId, int ordinal)? _attemptIdFactory;
  final Set<String> _activeOperationIds = <String>{};
  Completer<void>? _mutex;
  int _attemptOrdinal = 0;

  Future<NotificationReplyExecutionResult> execute({
    required NotificationReplyOperationIdentity identity,
    required NotificationReplyDispatch dispatch,
  }) async {
    late final _NotificationReplyReservation reservation;
    try {
      reservation = await _reserve(identity);
    } catch (_) {
      return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.journalUnavailable);
    }
    if (!reservation.mayDispatch) {
      return NotificationReplyExecutionResult(reservation.disposition);
    }

    var executionStarted = false;
    Future<void> markExecutionStarted() async {
      if (executionStarted) {
        return;
      }
      await _transition(
        identity: identity,
        attemptId: reservation.attemptId!,
        from: NotificationReplyOperationState.reserved,
        to: NotificationReplyOperationState.executionStarted,
      );
      executionStarted = true;
    }

    try {
      await dispatch(markExecutionStarted);
      if (!executionStarted) {
        await _transition(
          identity: identity,
          attemptId: reservation.attemptId!,
          from: NotificationReplyOperationState.reserved,
          to: NotificationReplyOperationState.preExecutionRejected,
        );
        return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.preExecutionRejected);
      }
      try {
        await _transition(
          identity: identity,
          attemptId: reservation.attemptId!,
          from: NotificationReplyOperationState.executionStarted,
          to: NotificationReplyOperationState.terminal,
        );
        return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.terminal);
      } catch (_) {
        await _bestEffortAmbiguous(identity, reservation.attemptId!);
        return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.outcomeAmbiguous);
      }
    } catch (_) {
      if (executionStarted) {
        await _bestEffortAmbiguous(identity, reservation.attemptId!);
        return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.outcomeAmbiguous);
      }
      try {
        await _transition(
          identity: identity,
          attemptId: reservation.attemptId!,
          from: NotificationReplyOperationState.reserved,
          to: NotificationReplyOperationState.preExecutionRejected,
        );
        return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.preExecutionRejected);
      } catch (_) {
        return const NotificationReplyExecutionResult(NotificationReplyExecutionDisposition.journalUnavailable);
      }
    } finally {
      await _withLock(() async {
        _activeOperationIds.remove(identity.operationId);
      });
    }
  }

  Future<_NotificationReplyReservation> _reserve(NotificationReplyOperationIdentity identity) => _withLock(() async {
    var journal = NotificationReplyOperationJournal.decode(await _load());
    final ordinal = ++_attemptOrdinal;
    final attemptId =
        _attemptIdFactory?.call(identity.operationId, ordinal) ??
        _fingerprint(
          'notification-reply-attempt-v1',
          '${identity.operationId}\u0000$processFingerprint\u0000${DateTime.now().microsecondsSinceEpoch}\u0000$ordinal',
        );
    var decision = journal.begin(identity: identity, attemptId: attemptId, processFingerprint: processFingerprint);
    final duplicateWithoutActiveOwner =
        decision.disposition == NotificationReplyBeginDisposition.duplicateInFlight &&
        !_activeOperationIds.contains(identity.operationId);
    if (decision.disposition == NotificationReplyBeginDisposition.recoverablePreExecutionReservation ||
        (duplicateWithoutActiveOwner && decision.record.state == NotificationReplyOperationState.reserved)) {
      journal = journal.transition(
        identity: identity,
        attemptId: decision.record.attemptId,
        from: NotificationReplyOperationState.reserved,
        to: NotificationReplyOperationState.preExecutionRejected,
      );
      await _save(journal.encode());
      decision = journal.begin(identity: identity, attemptId: attemptId, processFingerprint: processFingerprint);
    } else if ((decision.disposition == NotificationReplyBeginDisposition.ambiguousPriorExecution ||
            duplicateWithoutActiveOwner) &&
        decision.record.state == NotificationReplyOperationState.executionStarted) {
      journal = journal.transition(
        identity: identity,
        attemptId: decision.record.attemptId,
        from: NotificationReplyOperationState.executionStarted,
        to: NotificationReplyOperationState.outcomeAmbiguous,
      );
      await _save(journal.encode());
      return const _NotificationReplyReservation.blocked(NotificationReplyExecutionDisposition.outcomeAmbiguous);
    }

    switch (decision.disposition) {
      case NotificationReplyBeginDisposition.accepted:
        await _save(decision.journal.encode());
        _activeOperationIds.add(identity.operationId);
        return _NotificationReplyReservation.accepted(attemptId);
      case NotificationReplyBeginDisposition.duplicateInFlight:
        return const _NotificationReplyReservation.blocked(NotificationReplyExecutionDisposition.duplicateInFlight);
      case NotificationReplyBeginDisposition.alreadyTerminal:
        return const _NotificationReplyReservation.blocked(NotificationReplyExecutionDisposition.alreadyTerminal);
      case NotificationReplyBeginDisposition.ambiguousPriorExecution:
        return const _NotificationReplyReservation.blocked(NotificationReplyExecutionDisposition.outcomeAmbiguous);
      case NotificationReplyBeginDisposition.recoverablePreExecutionReservation:
        throw StateError('NOTIFICATION_REPLY_OPERATION_RECOVERY_DID_NOT_CONVERGE');
    }
  });

  Future<void> _transition({
    required NotificationReplyOperationIdentity identity,
    required String attemptId,
    required NotificationReplyOperationState from,
    required NotificationReplyOperationState to,
  }) => _withLock(() async {
    final journal = NotificationReplyOperationJournal.decode(
      await _load(),
    ).transition(identity: identity, attemptId: attemptId, from: from, to: to);
    await _save(journal.encode());
  });

  Future<void> _bestEffortAmbiguous(NotificationReplyOperationIdentity identity, String attemptId) async {
    try {
      await _transition(
        identity: identity,
        attemptId: attemptId,
        from: NotificationReplyOperationState.executionStarted,
        to: NotificationReplyOperationState.outcomeAmbiguous,
      );
    } catch (_) {
      // The last durable state remains execution_started, which is itself a
      // replay barrier and is reconciled to outcome_ambiguous after restart.
    }
  }

  Future<T> _withLock<T>(Future<T> Function() operation) async {
    while (_mutex != null) {
      await _mutex!.future;
    }
    final mutex = Completer<void>();
    _mutex = mutex;
    try {
      return await operation();
    } finally {
      if (identical(_mutex, mutex)) _mutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }
}

class _NotificationReplyReservation {
  const _NotificationReplyReservation.accepted(this.attemptId)
    : mayDispatch = true,
      disposition = NotificationReplyExecutionDisposition.preExecutionRejected;

  const _NotificationReplyReservation.blocked(this.disposition) : mayDispatch = false, attemptId = null;

  final bool mayDispatch;
  final String? attemptId;
  final NotificationReplyExecutionDisposition disposition;
}
