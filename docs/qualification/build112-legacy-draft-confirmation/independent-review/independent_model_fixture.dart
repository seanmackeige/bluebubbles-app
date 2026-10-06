import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';

String digest(String value) => sha256.convert(utf8.encode(value)).toString();
final current = LogicalAuthorityRevision(certificateRevision: digest('certificate'), authorityRevision: digest('authority'), epoch: 20);
final prior = LogicalAuthorityRevision(certificateRevision: digest('prior certificate'), authorityRevision: digest('prior authority'), epoch: 10);
final results = <String, Object?>{};
final failures = <String>[];
void check(String name, void Function() test) {
  try { test(); results[name] = 'PASS'; }
  catch (error) { failures.add(name); results[name] = 'FAIL: $error'; }
}
void require(bool condition, String message) { if (!condition) throw StateError(message); }
void rejects(void Function() operation) {
  bool rejected = false;
  try { operation(); } catch (_) { rejected = true; }
  require(rejected, 'Operation was accepted');
}
LogicalDraft legacy({String text = 'SANITIZED_RUNTIME_SHAPE', String logicalId = 'logical-fixture', int created = 1}) =>
    LogicalDraft.create(logicalId: logicalId, nowEpochMilliseconds: created).mergeUserIntent(
      text: text, subject: '', attachments: [], reply: null, effectId: null, updatedAtEpochMilliseconds: created + 1);
Map<String, String> facts(LogicalDraft draft) => {
  for (final key in LogicalDraftConfirmation.requiredFacts) key: digest('sanitized $key'),
  'action': draft.actionId, 'content': draft.contentFingerprint, 'logical': draft.logicalFingerprint,
  'certificate': current.certificateRevision, 'authority': current.authorityRevision,
};
LogicalDraftConfirmation proof(LogicalDraft draft, {int revision = 1, bool invalidated = false, Map<String, String>? suppliedFacts}) =>
    LogicalDraftConfirmation(revision: revision, invalidated: invalidated, facts: suppliedFacts ?? facts(draft), authorityEpoch: current.epoch);
LogicalDraft confirmed(LogicalDraft draft) => draft.confirm(proof(draft), nowEpochMilliseconds: 100);
LogicalDraft edit(LogicalDraft draft, {String? text, String? subject, List<LogicalAttachmentIntent>? attachments,
    LogicalReplyIntent? reply, String? effect, LogicalAuthorityRevision? observed}) => draft.mergeUserIntent(
      text: text ?? draft.text, subject: subject ?? draft.subject, attachments: attachments ?? draft.attachments,
      reply: reply, effectId: effect, observedRevision: observed, updatedAtEpochMilliseconds: 200);
Map<String, dynamic> roundTripMap(Map<String, dynamic> data) => (jsonDecode(jsonEncode(data)) as Map).cast<String, dynamic>();

void main() {
  final base = legacy();
  final observedKeys = ['observedCertificateRevision', 'observedAuthorityRevision', 'observedAuthorityEpoch'];
  final compositionKeys = ['compositionCertificateRevision', 'compositionAuthorityRevision', 'compositionAuthorityEpoch'];
  final values = <Object>[current.certificateRevision, current.authorityRevision, current.epoch];
  for (var observedMask = 0; observedMask < 8; observedMask++) {
    for (var compositionMask = 0; compositionMask < 8; compositionMask++) {
      check('raw tuple presence $observedMask/$compositionMask', () {
        final raw = base.toJson();
        for (var bit = 0; bit < 3; bit++) {
          if ((observedMask & (1 << bit)) != 0) raw[observedKeys[bit]] = values[bit];
          if ((compositionMask & (1 << bit)) != 0) raw[compositionKeys[bit]] = values[bit];
        }
        final expected = observedMask == 0 && compositionMask == 0
            ? LogicalDraftMetadataClass.legacyUnboundDraft
            : observedMask == 7 && (compositionMask == 0 || compositionMask == 7)
                ? LogicalDraftMetadataClass.modernBoundDraft
                : LogicalDraftMetadataClass.partiallyBoundInvalidDraft;
        require(LogicalDraft.fromJson(raw).metadataClass == expected, 'Wrong metadata class');
      });
    }
  }
  for (final key in [...observedKeys, ...compositionKeys]) {
    check('blank or zero is not missing $key', () {
      final raw = base.toJson()..[key] = key.endsWith('Epoch') ? 0 : ' ';
      require(LogicalDraft.fromJson(raw).metadataClass == LogicalDraftMetadataClass.partiallyBoundInvalidDraft, 'Blank was legacy');
    });
  }
  for (final key in ['observedAuthorityEpoch', 'compositionAuthorityEpoch']) {
    for (final value in <Object>[1.5, '20', true]) {
      check('malformed raw epoch $key/$value', () => rejects(() => LogicalDraft.fromJson(base.toJson()..[key] = value)));
    }
  }
  check('different complete composition is historical authority', () {
    final raw = base.rearm(current, updatedAtEpochMilliseconds: 3).toJson()
      ..['compositionCertificateRevision'] = prior.certificateRevision
      ..['compositionAuthorityRevision'] = prior.authorityRevision
      ..['compositionAuthorityEpoch'] = prior.epoch;
    require(LogicalDraft.fromJson(raw).metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Valid history rejected');
  });
  check('explicit null tuple remains missing', () {
    final raw = base.toJson(); for (final key in [...observedKeys, ...compositionKeys]) { raw[key] = null; }
    require(LogicalDraft.fromJson(raw).metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft, 'Null legacy changed');
  });
  check('humanless empty container cannot confirm', () => rejects(() {
    final empty = LogicalDraft.create(logicalId: 'empty-owner', nowEpochMilliseconds: 1);
    empty.confirm(proof(empty), nowEpochMilliseconds: 2);
  }));
  check('real S24 sanitized shape 51 chars revision11 all proof missing', () {
    final raw = base.toJson();
    raw['text'] = List.filled(51, 'x').join();
    raw['contentRevision'] = 11;
    final shaped = LogicalDraft.fromJson(raw);
    require(shaped.text.length == 51 && shaped.contentRevision == 11 && shaped.hasUserIntent &&
      shaped.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft, 'Runtime shape changed');
    final bound = confirmed(shaped);
    require(bound.text == shaped.text && bound.contentRevision == 11 && bound.actionId == shaped.actionId &&
      bound.metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Confirmation changed runtime-shaped intent');
    final drift = bound.rearm(prior, updatedAtEpochMilliseconds: 200);
    require(drift.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft && drift.confirmation!.invalidated,
      'Runtime-shaped confirmation survived material drift');
  });
  check('legacy nonempty explicit confirmation preserves custody', () {
    final result = confirmed(base);
    require(result.metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Not modern bound');
    require(result.actionId == base.actionId && result.contentFingerprint == base.contentFingerprint &&
      result.createdAtEpochMilliseconds == base.createdAtEpochMilliseconds && result.contentRevision == base.contentRevision, 'Intent changed');
    require(current.matchesDraft(result) && result.confirmation!.revision == 1, 'Proof not bound');
  });
  check('restart preserves exact confirmation', () {
    final result = confirmed(base);
    final restored = LogicalDraft.fromJson(roundTripMap(result.toJson()));
    require(jsonEncode(restored.toJson()) == jsonEncode(result.toJson()), 'Roundtrip changed confirmation');
    require(restored.metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Restart lost class');
  });
  check('duplicate confirmation cannot confirm modern again', () => rejects(() {
    final result = confirmed(base); result.confirm(proof(result, revision: 2), nowEpochMilliseconds: 102);
  }));
  for (final mutation in ['text', 'subject', 'attachment', 'reply', 'effect']) {
    check('confirmed then semantic edit $mutation', () {
      final result = confirmed(base);
      final changed = edit(result, text: mutation == 'text' ? 'changed' : null,
        subject: mutation == 'subject' ? 'changed subject' : null,
        attachments: mutation == 'attachment' ? [const LogicalAttachmentIntent(intentId: 'selection-1', name: 'sanitized', size: 2, isRestorable: false)] : null,
        reply: mutation == 'reply' ? const LogicalReplyIntent(messageGuid: 'sanitized-guid', relationshipTargetGuid: 'sanitized-parent', sourceChatRowId: 2155, sourceChatGuid: 'sanitized-chat', part: 0) : null,
        effect: mutation == 'effect' ? 'sanitized-effect' : null, observed: current);
      require(changed.actionId != result.actionId && changed.confirmation!.invalidated, 'Confirmation survived edit');
      require(changed.observedAuthorityEpoch == null && changed.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft, 'Edited draft silently bound');
      final restored = LogicalDraft.fromJson(roundTripMap(changed.toJson()));
      require(restored.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft && restored.confirmation!.invalidated, 'Restart forgot invalidation');
      final reconfirmed = restored.confirm(proof(restored, revision: 2), nowEpochMilliseconds: 300);
      require(reconfirmed.metadataClass == LogicalDraftMetadataClass.modernBoundDraft && reconfirmed.confirmation!.revision == 2, 'Reconfirmation not explicit');
    });
  }
  check('harmless republish retains confirmation', () {
    final result = confirmed(base); final copy = edit(result);
    require(copy.actionId == result.actionId && identical(copy.confirmation, result.confirmation), 'Harmless republish invalidated');
  });
  check('ordinary modern draft edit does not require legacy confirmation', () {
    final modern = LogicalDraft.create(logicalId: 'modern', nowEpochMilliseconds: 1, observedRevision: current);
    final next = edit(modern, text: 'new modern content');
    require(next.confirmation == null && next.metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Modern draft acquired extra step');
  });
  check('confirmed empty then retype cannot silently rebound', () {
    final empty = edit(confirmed(base), text: ''); final next = edit(empty, text: 'new text', observed: current);
    require(next.confirmation!.invalidated && next.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft, 'Empty rebind bypass');
  });
  for (final mutation in ['certificate', 'authority']) {
    check('material rearm invalidates confirmation $mutation', () {
      final changedRevision = LogicalAuthorityRevision(certificateRevision: mutation == 'certificate' ? digest('changed certificate') : current.certificateRevision,
        authorityRevision: mutation == 'authority' ? digest('changed authority') : current.authorityRevision, epoch: 21);
      final changed = confirmed(base).rearm(changedRevision, updatedAtEpochMilliseconds: 200);
      require(changed.confirmation!.invalidated && changed.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft, 'Material change retained confirmation');
    });
  }
  check('epoch-only metadata rearm preserves human confirmation', () {
    final result = confirmed(base);
    final refreshed = result.rearm(LogicalAuthorityRevision(certificateRevision: current.certificateRevision, authorityRevision: current.authorityRevision, epoch: 21), updatedAtEpochMilliseconds: 200);
    require(refreshed.metadataClass == LogicalDraftMetadataClass.modernBoundDraft && !refreshed.confirmation!.invalidated, 'Harmless verified epoch metadata invalidated');
    require(refreshed.confirmation!.authorityEpoch == 20 && refreshed.observedAuthorityEpoch == 21, 'Original confirmation epoch rewritten');
  });
  for (final missing in LogicalDraftConfirmation.requiredFacts) {
    check('missing proof fact $missing rejected', () => rejects(() => proof(base, suppliedFacts: facts(base)..remove(missing))));
  }
  check('extra proof field rejected', () => rejects(() => proof(base, suppliedFacts: facts(base)..['unexpected'] = digest('extra'))));
  check('wrong proof fingerprint rejected', () => rejects(() => proof(base, suppliedFacts: facts(base)..['writer'] = 'bad')));
  for (final mismatch in ['action', 'content', 'logical']) {
    check('confirmation cannot bind wrong $mismatch', () => rejects(() => base.confirm(proof(base, suppliedFacts: facts(base)..[mismatch] = digest('wrong')), nowEpochMilliseconds: 100)));
  }
  for (final mismatch in ['action', 'content', 'logical', 'certificate', 'authority']) {
    check('persisted current confirmation contradicts $mismatch', () {
      final raw = roundTripMap(confirmed(base).toJson());
      (raw['confirmation']['facts'] as Map)[mismatch] = digest('wrong');
      require(LogicalDraft.fromJson(raw).metadataClass == LogicalDraftMetadataClass.partiallyBoundInvalidDraft, 'Contradiction accepted');
    });
  }
  check('invalidated cross-owner proof is contradictory, not legacy', () {
    final raw = roundTripMap(edit(confirmed(base), text: 'changed').toJson());
    (raw['confirmation']['facts'] as Map)['logical'] = digest('different owner');
    require(LogicalDraft.fromJson(raw).metadataClass == LogicalDraftMetadataClass.partiallyBoundInvalidDraft, 'Wrong owner entered legacy shortcut');
  });
  check('partial metadata cannot be confirmed', () => rejects(() {
    final partial = LogicalDraft.fromJson(base.toJson()..['observedAuthorityEpoch'] = 20);
    partial.confirm(proof(partial), nowEpochMilliseconds: 100);
  }));
  check('empty attachment-only intent can explicitly confirm', () {
    final attached = edit(legacy(text: ''), attachments: [const LogicalAttachmentIntent(intentId: 'attachment', name: 'sanitized', size: 1, isRestorable: false)]);
    require(confirmed(attached).metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Attachment intent not confirmable');
  });
  check('malformed confirmation record is unreadable', () => rejects(() {
    final raw = confirmed(base).toJson()..['confirmation'] = {'schema': 'LOGICAL_DRAFT_CONFIRMATION_V1', 'revision': 1};
    LogicalDraft.fromJson(raw);
  }));
  print(jsonEncode({'scope': 'Actual pure model only; no provider, persistence, queue, reservation or transport',
    'caseCount': results.length, 'failures': failures, 'results': results}));
  if (failures.isNotEmpty) exitCode = 1;
}
