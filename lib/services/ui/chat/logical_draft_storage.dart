import 'dart:convert';

import 'logical_conversation_identity.dart';
import 'logical_draft.dart';

/// Storage ownership is the application identity. Serialized draft identity is
/// immutable: changing it would also change contentFingerprint and actionId.
class LogicalDraftStorage {
  LogicalDraftStorage(String certificateId)
    : legacyKey = certificateId,
      canonicalKey = LogicalConversationId.certified(certificateId).value;

  final String canonicalKey;
  final String legacyKey;

  LogicalDraftSlot read(String? Function(String) read) {
    final populated = <String, LogicalDraft>{};
    for (final key in <String>[canonicalKey, legacyKey]) {
      final raw = read(key);
      if (raw == null) continue;
      try {
        final draft = LogicalDraft.fromJson((jsonDecode(raw) as Map).cast<String, dynamic>());
        if (draft.logicalId != canonicalKey && draft.logicalId != legacyKey) {
          throw const FormatException('DRAFT_IDENTITY_CHANGED');
        }
        populated[key] = draft;
      } catch (_) {
        throw StateError('LOGICAL_DRAFT_STORAGE_UNREADABLE');
      }
    }
    if (populated.length == 2 &&
        jsonEncode(populated.values.first.toJson()) != jsonEncode(populated.values.last.toJson())) {
      throw StateError('LOGICAL_DRAFT_STORAGE_CONFLICT');
    }
    return LogicalDraftSlot(
      storageKey: populated.keys.firstOrNull ?? canonicalKey,
      occupiedKeys: populated.keys.toList(growable: false),
      draft: populated.values.firstOrNull,
    );
  }
}

class LogicalDraftSlot {
  const LogicalDraftSlot({required this.storageKey, required this.occupiedKeys, required this.draft});
  final String storageKey;
  final List<String> occupiedKeys;
  final LogicalDraft? draft;
}
