import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_storage.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_confirmation_transaction.dart';

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
LogicalDraft fixture() => LogicalDraft(
  logicalId: LogicalDraftStorage('fixture').canonicalKey,
  text: List.filled(51, 'x').join(),
  subject: '',
  attachments: [],
  contentRevision: 11,
  createdAtEpochMilliseconds: 1,
  updatedAtEpochMilliseconds: 2,
);
LogicalDraftConfirmation proof(LogicalDraft draft) => LogicalDraftConfirmation(
  revision: 1,
  invalidated: false,
  authorityEpoch: 10,
  facts: {
    for (final key in LogicalDraftConfirmation.requiredFacts) key: digest(key),
    'action': draft.actionId,
    'content': draft.contentFingerprint,
    'logical': draft.logicalFingerprint,
  },
);
void main() {
  test('Build111 real shape stays unbound until separate confirmation; same operation identity', () {
    final draft = fixture();
    expect(draft.metadataClass, LogicalDraftMetadataClass.legacyUnboundDraft);
    final confirmed = draft.confirm(proof(draft), nowEpochMilliseconds: 3);
    expect(confirmed.metadataClass, LogicalDraftMetadataClass.modernBoundDraft);
    expect(confirmed.actionId, draft.actionId);
    expect(confirmed.contentFingerprint, draft.contentFingerprint);
    expect(confirmed.contentRevision, 11);
    expect(LogicalDraft.fromJson(confirmed.toJson()).confirmation!.facts, confirmed.confirmation!.facts);
  });
  test('all raw partial tuple permutations fail closed without per-field fallback', () {
    const keys = [
      'observedCertificateRevision',
      'observedAuthorityRevision',
      'observedAuthorityEpoch',
      'compositionCertificateRevision',
      'compositionAuthorityRevision',
      'compositionAuthorityEpoch',
    ];
    for (var mask = 0; mask < 64; mask++) {
      final raw = fixture().toJson();
      for (var bit = 0; bit < 6; bit++) {
        if (mask & (1 << bit) != 0) raw[keys[bit]] = bit % 3 == 2 ? 10 : digest('proof');
      }
      final expected = mask == 0
          ? LogicalDraftMetadataClass.legacyUnboundDraft
          : mask == 7 || mask == 63
          ? LogicalDraftMetadataClass.modernBoundDraft
          : LogicalDraftMetadataClass.partiallyBoundInvalidDraft;
      expect(LogicalDraft.fromJson(raw).metadataClass, expected, reason: 'mask $mask');
    }
  });
  test('semantic edits invalidate while unchanged republishing and restart preserve', () {
    final draft = fixture();
    final confirmed = draft.confirm(proof(draft), nowEpochMilliseconds: 3);
    LogicalDraft update(String text) => confirmed.mergeUserIntent(
      text: text,
      subject: '',
      attachments: [],
      reply: null,
      effectId: null,
      updatedAtEpochMilliseconds: 4,
    );
    expect(update(confirmed.text).metadataClass, LogicalDraftMetadataClass.modernBoundDraft);
    final edited = update('human edit');
    expect(edited.metadataClass, LogicalDraftMetadataClass.legacyUnboundDraft);
    expect(LogicalDraft.fromJson(edited.toJson()).confirmation!.invalidated, isTrue);
    expect(edited.observedAuthorityRevision, isNull);
  });
  for (final mutation in ['certificate', 'authority']) {
    test('material $mutation drift revokes human confirmation', () {
      final draft = fixture();
      final confirmed = draft.confirm(proof(draft), nowEpochMilliseconds: 3);
      final changed = confirmed.rearm(
        LogicalAuthorityRevision(
          certificateRevision: mutation == 'certificate' ? digest('changed') : digest('certificate'),
          authorityRevision: mutation == 'authority' ? digest('changed') : digest('authority'),
          epoch: 11,
        ),
        updatedAtEpochMilliseconds: 4,
      );
      expect(changed.metadataClass, LogicalDraftMetadataClass.legacyUnboundDraft);
      expect(changed.actionId, draft.actionId);
    });
  }
  for (final failure in ['none', 'before write', 'after write', 'authority during write', 'newer human draft']) {
    test('confirmation transaction $failure preserves custody and cannot dispatch', () async {
      final draft = fixture();
      final storage = LogicalDraftStorage('fixture');
      var raw = jsonEncode(draft.toJson());
      var current = true;
      var writes = 0;
      final newer = draft.mergeUserIntent(
        text: 'human changed',
        subject: '',
        attachments: [],
        reply: null,
        effectId: null,
        updatedAtEpochMilliseconds: 8,
      );
      final result = confirmLogicalDraftAtomically(
        expected: draft,
        proof: proof(draft),
        read: () => storage.read((key) => key == storage.canonicalKey ? raw : null),
        write: (key, value) async {
          writes++;
          if (writes == 1 && failure == 'before write') throw StateError('injected');
          raw = value;
          if (writes == 1 && failure == 'after write') throw StateError('injected');
          if (writes == 1 && failure == 'authority during write') current = false;
          if (writes == 1 && failure == 'newer human draft') raw = jsonEncode(newer.toJson());
        },
        contextIsCurrent: () => current,
        nowEpochMilliseconds: 3,
      );
      if (failure == 'none') {
        expect((await result).metadataClass, LogicalDraftMetadataClass.modernBoundDraft);
        expect(writes, 1);
      } else {
        await expectLater(result, throwsStateError);
        final retained = LogicalDraft.fromJson(jsonDecode(raw));
        expect(retained.metadataClass, LogicalDraftMetadataClass.legacyUnboundDraft);
        expect(
          retained.contentFingerprint,
          failure == 'newer human draft' ? newer.contentFingerprint : draft.contentFingerprint,
        );
      }
    });
  }
}
