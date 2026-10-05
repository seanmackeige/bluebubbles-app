import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_storage.dart';

void main() {
  final owner = LogicalDraftStorage('sanitized-certified-conversation');
  LogicalDraft draft(String id, {int created = 100}) =>
      LogicalDraft.create(logicalId: id, nowEpochMilliseconds: created).mergeUserIntent(
        text: 'sanitized intent',
        subject: '',
        attachments: [],
        reply: null,
        effectId: null,
        updatedAtEpochMilliseconds: 101,
      );
  String encode(LogicalDraft d) => jsonEncode(d.toJson());

  test('new draft uses canonical owner without changing certificate identity', () {
    final slot = owner.read((_) => null);
    expect(slot.storageKey, owner.canonicalKey);
    expect(owner.legacyKey, 'sanitized-certified-conversation');
    expect(owner.canonicalKey, isNot(owner.legacyKey));
  });
  for (final storageKey in [owner.legacyKey, owner.canonicalKey]) {
    for (final serializedId in [owner.legacyKey, owner.canonicalKey]) {
      test('preserves existing storage and replay identity $storageKey / $serializedId', () {
        final original = draft(serializedId);
        final rows = <String, String>{storageKey: encode(original)};
        final slot = owner.read((key) => rows[key]);
        expect(slot.storageKey, storageKey);
        expect(slot.draft!.logicalId, original.logicalId);
        expect(slot.draft!.actionId, original.actionId);
        expect(slot.draft!.contentFingerprint, original.contentFingerprint);
        expect(rows, {storageKey: encode(original)});
      });
    }
  }
  test('conflicting dual slots are blocked and retained without choosing newest', () {
    final rows = {
      owner.legacyKey: encode(draft(owner.legacyKey)),
      owner.canonicalKey: encode(draft(owner.canonicalKey, created: 200)),
    };
    final before = Map.of(rows);
    expect(() => owner.read((key) => rows[key]), throwsStateError);
    expect(rows, before);
  });
  test('identical redundant slots retain exact action identity and both custody keys', () {
    final original = draft(owner.legacyKey);
    final rows = {owner.legacyKey: encode(original), owner.canonicalKey: encode(original)};
    final slot = owner.read((key) => rows[key]);
    expect(slot.occupiedKeys.toSet(), rows.keys.toSet());
    expect(slot.draft!.actionId, original.actionId);
  });
  for (final bad in ['', '{', encode(draft('different-owner'))]) {
    test('unreadable or foreign identity never becomes an empty draft ${bad.length}', () {
      final rows = {owner.canonicalKey: bad};
      expect(() => owner.read((key) => rows[key]), throwsStateError);
      expect(rows[owner.canonicalKey], bad);
    });
  }
}
