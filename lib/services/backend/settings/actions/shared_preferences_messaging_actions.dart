import 'dart:convert';

import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';
import 'package:bluebubbles/services/ui/chat/logical_certificate_advancement_transaction.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_certificate_ledger.dart';

const _corruptLogicalAdmissionLedger = <Map<String, dynamic>>[
  <String, dynamic>{'schema': 'CORRUPT_LOGICAL_ADMISSION_LEDGER'},
];

List<Map<String, dynamic>> decodeLogicalAdmissionLedger(String? raw) {
  if (raw == null) return <Map<String, dynamic>>[];
  if (raw.isEmpty) return _corruptLogicalAdmissionLedger;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.any((item) => item is! Map)) {
      return _corruptLogicalAdmissionLedger;
    }
    return decoded.map((item) => Map<String, dynamic>.from(item as Map)).toList(growable: false);
  } catch (_) {
    return _corruptLogicalAdmissionLedger;
  }
}

class ReplyToMessageState {
  final String messageGuid;
  final int messagePart;

  const ReplyToMessageState({required this.messageGuid, required this.messagePart});
}

class RecentReplyState {
  final String messageGuid;
  final String text;

  const RecentReplyState({required this.messageGuid, required this.text});
}

class LogicalReadAuthoritySnapshot {
  const LogicalReadAuthoritySnapshot({required this.ledgerJson, required this.legacyCertificateJson});

  final String? ledgerJson;
  final String? legacyCertificateJson;

  String? get legacyFallbackJson => ledgerJson == null ? legacyCertificateJson : null;
}

class SharedPreferencesMessagingActions {
  static const String _lastOpenedChatKey = 'lastOpenedChat';
  static const String _recentReplyKey = 'recent-reply';
  static const String _notificationReplyOperationJournalKey = 'notificationReplyOperationJournalV1';
  static const String _replyToMessagePrefix = 'replyToMessage';
  static const String _replyToMessagePartPrefix = 'replyToMessagePart';
  static const String _logicalDraftPrefix = 'logicalDraftV1';
  static const String _logicalAdmissionLedgerKey = 'logicalAdmissionLedgerV1';
  static const String _logicalReadCertificateKey = 'logicalReadCertificateV1';
  static const String _logicalReadCertificateLedgerKey = 'logicalReadCertificateLedgerV2';
  static const String _logicalUnreadLedgerPrefix = 'logicalUnreadLedgerV1';
  static const String _logicalReadSyncPendingPrefix = 'logicalReadSyncPendingV1';
  static const String _logicalConversationSettingsKey = 'logicalConversationSettingsV1';
  static const String _logicalCandidateQuarantineKey = 'logicalCandidateQuarantineV1';
  static const String _logicalCandidateReconciliationContextsKey = 'logicalCandidateReconciliationContextsV1';
  static const String _logicalDeferredNotificationKey = 'logicalDeferredNotificationV1';

  final SharedPreferencesService service;

  static final LogicalCertificateAdvancementTransactionQueue _logicalCertificateAdvancementQueue =
      LogicalCertificateAdvancementTransactionQueue();

  SharedPreferencesMessagingActions(this.service);

  String _replyMessageKey(String chatGuid) => '${_replyToMessagePrefix}_$chatGuid';

  String _replyMessagePartKey(String chatGuid) => '${_replyToMessagePartPrefix}_$chatGuid';

  String _logicalDraftKey(String logicalId) => '${_logicalDraftPrefix}_$logicalId';

  String _logicalUnreadLedgerKey(String logicalId) => '${_logicalUnreadLedgerPrefix}_$logicalId';

  String _logicalReadSyncPendingKey(String logicalId) => '${_logicalReadSyncPendingPrefix}_$logicalId';

  String? getLastOpenedChat() => service.i.getString(_lastOpenedChatKey);

  Future<void> setLastOpenedChat(String chatGuid) async {
    await service.i.setString(_lastOpenedChatKey, chatGuid);
  }

  Future<void> clearLastOpenedChat() async {
    await service.i.remove(_lastOpenedChatKey);
  }

  Future<void> saveReplyToMessageState({required String chatGuid, String? messageGuid, int? messagePart}) async {
    if (messageGuid != null && messagePart != null) {
      await service.i.setString(_replyMessageKey(chatGuid), messageGuid);
      await service.i.setInt(_replyMessagePartKey(chatGuid), messagePart);
      return;
    }

    await service.i.remove(_replyMessageKey(chatGuid));
    await service.i.remove(_replyMessagePartKey(chatGuid));
  }

  ReplyToMessageState? loadReplyToMessageState(String chatGuid) {
    final messageGuid = service.i.getString(_replyMessageKey(chatGuid));
    final messagePart = service.i.getInt(_replyMessagePartKey(chatGuid));

    if (messageGuid == null || messagePart == null) return null;
    return ReplyToMessageState(messageGuid: messageGuid, messagePart: messagePart);
  }

  RecentReplyState? getRecentReply() {
    final raw = service.i.getString(_recentReplyKey);
    if (raw == null || raw.isEmpty) return null;

    final divider = raw.indexOf('/');
    if (divider <= 0 || divider >= raw.length - 1) return null;

    return RecentReplyState(messageGuid: raw.substring(0, divider), text: raw.substring(divider + 1));
  }

  String? getRecentReplyRaw() => service.i.getString(_recentReplyKey);

  Future<void> setRecentReply({required String messageGuid, required String text}) async {
    await service.i.setString(_recentReplyKey, '$messageGuid/$text');
  }

  Future<String?> loadNotificationReplyOperationJournalFresh() async {
    await service.i.reloadCache();
    return service.i.getString(_notificationReplyOperationJournalKey);
  }

  Future<void> saveNotificationReplyOperationJournal(String value) async {
    await service.i.setString(_notificationReplyOperationJournalKey, value);
  }

  String? loadLogicalDraftJson(String logicalId) => service.i.getString(_logicalDraftKey(logicalId));

  Future<void> saveLogicalDraftJson(String logicalId, String value) async {
    await service.i.setString(_logicalDraftKey(logicalId), value);
  }

  Future<void> clearLogicalDraft(String logicalId) async {
    await service.i.remove(_logicalDraftKey(logicalId));
  }

  String? loadLogicalUnreadLedgerJson(String logicalId) => service.i.getString(_logicalUnreadLedgerKey(logicalId));

  Future<void> saveLogicalUnreadLedgerJson(String logicalId, String value) async {
    await service.i.setString(_logicalUnreadLedgerKey(logicalId), value);
  }

  Future<void> clearLogicalUnreadLedger(String logicalId) => service.i.remove(_logicalUnreadLedgerKey(logicalId));
  bool loadLogicalReadSyncPending(String logicalId) =>
      service.i.getBool(_logicalReadSyncPendingKey(logicalId)) ?? false;

  Future<void> saveLogicalReadSyncPending(String logicalId, bool value) async {
    await service.i.setBool(_logicalReadSyncPendingKey(logicalId), value);
  }

  String? loadLogicalReadCertificateJson() => service.i.getString(_logicalReadCertificateKey);

  Future<String?> loadLogicalReadCertificateJsonFresh() async {
    await service.i.reloadCache();
    return service.i.getString(_logicalReadCertificateKey);
  }

  String? loadLogicalReadCertificateLedgerJson() => service.i.getString(_logicalReadCertificateLedgerKey);

  Future<String?> loadLogicalReadCertificateLedgerJsonFresh() async {
    await service.i.reloadCache();
    return service.i.getString(_logicalReadCertificateLedgerKey);
  }

  /// Reloads shared preferences exactly once and captures the complete
  /// certificate authority state. Presence of V2 is authoritative even when
  /// corrupt; callers may consult V1 only when V2 is absent.
  Future<LogicalReadAuthoritySnapshot> loadLogicalReadAuthorityFresh() async {
    await service.i.reloadCache();
    return LogicalReadAuthoritySnapshot(
      ledgerJson: service.i.getString(_logicalReadCertificateLedgerKey),
      legacyCertificateJson: service.i.getString(_logicalReadCertificateKey),
    );
  }

  Future<void> saveLogicalReadCertificateLedgerJson(String value) async {
    LogicalConversationCertificateLedger.decode(value);
    await service.i.setString(_logicalReadCertificateLedgerKey, value);
  }

  /// Advances one trusted authority under the process-wide transaction queue.
  /// Every contender reloads durable state after acquiring the queue, so a
  /// different authority is preserved and a stale same-authority revision is
  /// rejected before any write.
  Future<LogicalCertificateAdvancementResult> commitLogicalReadCertificateAdvancement({
    required String runtimeCertificateJson,
    required String expectedPersistedCertificateRevision,
    required ActivateLogicalCertificateAuthority activateAuthority,
  }) => _logicalCertificateAdvancementQueue.commit(
    runtimeCertificateJson: runtimeCertificateJson,
    expectedPersistedCertificateRevision: expectedPersistedCertificateRevision,
    loadAuthority: () async {
      await service.i.reloadCache();
      return LogicalCertificateAuthorityState(
        ledgerJson: service.i.getString(_logicalReadCertificateLedgerKey),
        legacyCertificateJson: service.i.getString(_logicalReadCertificateKey),
      );
    },
    persistAuthority: (ledgerJson, bankedLegacyCertificateJson) async {
      await service.i.setString(_logicalReadCertificateLedgerKey, ledgerJson);
      if (bankedLegacyCertificateJson != null) {
        await service.i.setString(_logicalReadCertificateKey, bankedLegacyCertificateJson);
      }
    },
    activateAuthority: activateAuthority,
  );

  String? loadLogicalConversationSettingsJson() => service.i.getString(_logicalConversationSettingsKey);

  Future<void> saveLogicalConversationSettingsJson(String value) async {
    await service.i.setString(_logicalConversationSettingsKey, value);
  }

  String? loadLogicalCandidateQuarantineJson() => service.i.getString(_logicalCandidateQuarantineKey);

  Future<void> saveLogicalCandidateQuarantineJson(String value) async {
    await service.i.setString(_logicalCandidateQuarantineKey, value);
  }

  String? loadLogicalCandidateReconciliationContextsJson() =>
      service.i.getString(_logicalCandidateReconciliationContextsKey);

  Future<void> saveLogicalCandidateReconciliationContextsJson(String value) async {
    await service.i.setString(_logicalCandidateReconciliationContextsKey, value);
  }

  String? loadLogicalDeferredNotificationJson() => service.i.getString(_logicalDeferredNotificationKey);

  Future<void> saveLogicalDeferredNotificationJson(String value) async {
    await service.i.setString(_logicalDeferredNotificationKey, value);
  }

  List<Map<String, dynamic>> loadLogicalAdmissionLedger() {
    return decodeLogicalAdmissionLedger(service.i.getString(_logicalAdmissionLedgerKey));
  }

  Future<void> saveLogicalAdmissionLedger(List<Map<String, dynamic>> entries) async {
    await service.i.setString(_logicalAdmissionLedgerKey, jsonEncode(entries));
  }
}
