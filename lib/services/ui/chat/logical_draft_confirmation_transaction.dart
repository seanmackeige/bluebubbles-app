import 'dart:convert';

import 'logical_draft.dart';
import 'logical_draft_storage.dart';

/// Called under the same serialized lock as draft saves/consumption. One
/// preference value contains both content and proof. Ambiguous dual-slot
/// custody cannot be upgraded by two sequential writes.
Future<LogicalDraft> confirmLogicalDraftAtomically({
  required LogicalDraft expected,
  required LogicalDraftConfirmation proof,
  required LogicalDraftSlot Function() read,
  required Future<void> Function(String, String) write,
  required bool Function() contextIsCurrent,
  required int nowEpochMilliseconds,
}) async {
  final slot = read();
  final current = slot.draft;
  if (slot.occupiedKeys.length != 1 ||
      current == null ||
      !contextIsCurrent() ||
      jsonEncode(current.toJson()) != jsonEncode(expected.toJson())) {
    throw StateError('CONFIRMATION_DRAFT_OR_CONTEXT_CHANGED');
  }
  final confirmed = current.confirm(proof, nowEpochMilliseconds: nowEpochMilliseconds);
  final encoded = jsonEncode(confirmed.toJson());
  try {
    // Linearization point: the exact content and its proof are one record.
    await write(slot.storageKey, encoded);
    final after = read();
    if (!contextIsCurrent() ||
        after.occupiedKeys.length != 1 ||
        after.storageKey != slot.storageKey ||
        after.draft == null ||
        jsonEncode(after.draft!.toJson()) != encoded) {
      throw StateError('CONFIRMATION_NOT_READY_AFTER_PERSISTENCE');
    }
    return confirmed;
  } catch (_) {
    // Revoke only our exact record. Never overwrite a newer human draft or
    // conflicting slot. Includes a write that took effect before throwing.
    final after = read();
    if (after.occupiedKeys.length == 1 &&
        after.storageKey == slot.storageKey &&
        after.draft != null &&
        jsonEncode(after.draft!.toJson()) == encoded) {
      await write(slot.storageKey, jsonEncode(confirmed.invalidateConfirmation().toJson()));
    }
    rethrow;
  }
}
