import 'dart:convert';

import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';

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

class SharedPreferencesMessagingActions {
  static const String _lastOpenedChatKey = 'lastOpenedChat';
  static const String _recentReplyKey = 'recent-reply';
  static const String _replyToMessagePrefix = 'replyToMessage';
  static const String _replyToMessagePartPrefix = 'replyToMessagePart';
  static const String _logicalDraftPrefix = 'logicalDraftV1';
  static const String _logicalAdmissionLedgerKey = 'logicalAdmissionLedgerV1';

  final SharedPreferencesService service;

  SharedPreferencesMessagingActions(this.service);

  String _replyMessageKey(String chatGuid) => '${_replyToMessagePrefix}_$chatGuid';

  String _replyMessagePartKey(String chatGuid) => '${_replyToMessagePartPrefix}_$chatGuid';

  String _logicalDraftKey(String logicalId) => '${_logicalDraftPrefix}_$logicalId';

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

  String? loadLogicalDraftJson(String logicalId) => service.i.getString(_logicalDraftKey(logicalId));

  Future<void> saveLogicalDraftJson(String logicalId, String value) async {
    await service.i.setString(_logicalDraftKey(logicalId), value);
  }

  Future<void> clearLogicalDraft(String logicalId) async {
    await service.i.remove(_logicalDraftKey(logicalId));
  }

  List<Map<String, dynamic>> loadLogicalAdmissionLedger() {
    return decodeLogicalAdmissionLedger(service.i.getString(_logicalAdmissionLedgerKey));
  }

  Future<void> saveLogicalAdmissionLedger(List<Map<String, dynamic>> entries) async {
    await service.i.setString(_logicalAdmissionLedgerKey, jsonEncode(entries));
  }
}
