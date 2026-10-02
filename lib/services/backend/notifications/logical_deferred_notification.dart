import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';

const logicalDeferredNotificationSchema = 'LOGICAL_DEFERRED_NOTIFICATION_V1';
const logicalDeferredNotificationMaxEntries = 64;
const logicalDeferredNotificationTtl = Duration(hours: 24);

enum LogicalProtectedNotificationDisposition { emitNormal, defer, emitReadOnly }

/// Keeps active candidate evidence out of a duplicate notification thread,
/// while ensuring a terminally rejected/expired physical conversation does
/// not lose inbound alerts forever. Terminal alerts are display-only: they do
/// not expose reply, read, reaction, bubble, or direct-share mutations.
LogicalProtectedNotificationDisposition resolveProtectedLogicalNotification({
  required bool isPotentialLogicalSource,
  required bool isCertifiedLogicalConversation,
  required LogicalCandidateQuarantinePhase? candidatePhase,
}) {
  if (isCertifiedLogicalConversation || !isPotentialLogicalSource) {
    return LogicalProtectedNotificationDisposition.emitNormal;
  }
  if (candidatePhase == LogicalCandidateQuarantinePhase.rejected ||
      candidatePhase == LogicalCandidateQuarantinePhase.expiredVisible) {
    return LogicalProtectedNotificationDisposition.emitReadOnly;
  }
  return LogicalProtectedNotificationDisposition.defer;
}

bool shouldDeferProtectedLogicalNotification({
  required bool isPotentialLogicalSource,
  required bool isCertifiedLogicalConversation,
}) =>
    resolveProtectedLogicalNotification(
      isPotentialLogicalSource: isPotentialLogicalSource,
      isCertifiedLogicalConversation: isCertifiedLogicalConversation,
      candidatePhase: null,
    ) ==
    LogicalProtectedNotificationDisposition.defer;

class LogicalDeferredNotification {
  const LogicalDeferredNotification({
    required this.messageGuid,
    required this.sourceChatGuid,
    required this.enqueuedAtEpochMilliseconds,
  });

  final String messageGuid;
  final String sourceChatGuid;
  final int enqueuedAtEpochMilliseconds;

  String get key => '$sourceChatGuid\u0000$messageGuid';

  bool isExpiredAt(int nowEpochMilliseconds) =>
      nowEpochMilliseconds - enqueuedAtEpochMilliseconds > logicalDeferredNotificationTtl.inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'messageGuid': messageGuid,
    'sourceChatGuid': sourceChatGuid,
    'enqueuedAtEpochMilliseconds': enqueuedAtEpochMilliseconds,
  };

  factory LogicalDeferredNotification.fromJson(Map<String, dynamic> json) {
    final messageGuid = json['messageGuid'];
    final sourceChatGuid = json['sourceChatGuid'];
    final enqueuedAt = json['enqueuedAtEpochMilliseconds'];
    if (messageGuid is! String || messageGuid.isEmpty || sourceChatGuid is! String || sourceChatGuid.isEmpty) {
      throw const FormatException('LOGICAL_DEFERRED_NOTIFICATION_IDENTITY_INVALID');
    }
    if (enqueuedAt is! int || enqueuedAt < 0) {
      throw const FormatException('LOGICAL_DEFERRED_NOTIFICATION_TIME_INVALID');
    }
    return LogicalDeferredNotification(
      messageGuid: messageGuid,
      sourceChatGuid: sourceChatGuid,
      enqueuedAtEpochMilliseconds: enqueuedAt,
    );
  }
}

class LogicalDeferredNotificationLedger {
  LogicalDeferredNotificationLedger._(Map<String, LogicalDeferredNotification> entries)
    : _entries = Map<String, LogicalDeferredNotification>.unmodifiable(entries);

  factory LogicalDeferredNotificationLedger.empty() =>
      LogicalDeferredNotificationLedger._(const <String, LogicalDeferredNotification>{});

  factory LogicalDeferredNotificationLedger.decode(String? raw) {
    if (raw == null || raw.isEmpty) return LogicalDeferredNotificationLedger.empty();
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['schema'] != logicalDeferredNotificationSchema || decoded['entries'] is! List) {
      throw const FormatException('LOGICAL_DEFERRED_NOTIFICATION_LEDGER_INVALID');
    }
    final entries = <String, LogicalDeferredNotification>{};
    for (final rawEntry in decoded['entries'] as List) {
      if (rawEntry is! Map) throw const FormatException('LOGICAL_DEFERRED_NOTIFICATION_ENTRY_INVALID');
      final entry = LogicalDeferredNotification.fromJson(rawEntry.cast<String, dynamic>());
      if (entries.containsKey(entry.key)) {
        throw const FormatException('LOGICAL_DEFERRED_NOTIFICATION_DUPLICATE');
      }
      entries[entry.key] = entry;
    }
    if (entries.length > logicalDeferredNotificationMaxEntries) {
      throw const FormatException('LOGICAL_DEFERRED_NOTIFICATION_LEDGER_OVERSIZED');
    }
    return LogicalDeferredNotificationLedger._(entries);
  }

  final Map<String, LogicalDeferredNotification> _entries;

  List<LogicalDeferredNotification> get entries {
    final sorted = _entries.values.toList(growable: false)
      ..sort((a, b) {
        final byTime = a.enqueuedAtEpochMilliseconds.compareTo(b.enqueuedAtEpochMilliseconds);
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });
    return sorted;
  }

  LogicalDeferredNotificationLedger defer(LogicalDeferredNotification entry, {required int nowEpochMilliseconds}) {
    final working = <String, LogicalDeferredNotification>{
      for (final current in _entries.values)
        if (!current.isExpiredAt(nowEpochMilliseconds)) current.key: current,
    };
    working.putIfAbsent(entry.key, () => entry);
    final ordered = working.values.toList()
      ..sort((a, b) {
        final byTime = a.enqueuedAtEpochMilliseconds.compareTo(b.enqueuedAtEpochMilliseconds);
        return byTime != 0 ? byTime : a.key.compareTo(b.key);
      });
    while (ordered.length > logicalDeferredNotificationMaxEntries) {
      working.remove(ordered.removeAt(0).key);
    }
    return LogicalDeferredNotificationLedger._(working);
  }

  LogicalDeferredNotificationLedger remove(String key) {
    if (!_entries.containsKey(key)) return this;
    return LogicalDeferredNotificationLedger._(<String, LogicalDeferredNotification>{..._entries}..remove(key));
  }

  LogicalDeferredNotificationLedger prune({required int nowEpochMilliseconds}) =>
      LogicalDeferredNotificationLedger._(<String, LogicalDeferredNotification>{
        for (final entry in _entries.values)
          if (!entry.isExpiredAt(nowEpochMilliseconds)) entry.key: entry,
      });

  String encode() => jsonEncode(<String, dynamic>{
    'schema': logicalDeferredNotificationSchema,
    'entries': entries.map((entry) => entry.toJson()).toList(growable: false),
  });
}
