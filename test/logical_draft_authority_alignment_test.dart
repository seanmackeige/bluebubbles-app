import 'package:flutter_test/flutter_test.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_authority_alignment.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_admission_probe.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_intent_guard.dart';

const old = LogicalAuthorityRevision(certificateRevision: 'cert', authorityRevision: 'authority', epoch: 10);
const live = LogicalAuthorityRevision(certificateRevision: 'cert', authorityRevision: 'authority', epoch: 20);
LogicalDraft draft([LogicalAuthorityRevision? r = old]) =>
    LogicalDraft.create(logicalId: 'logical', nowEpochMilliseconds: 1, observedRevision: r).mergeUserIntent(
      text: 'offline fixture',
      subject: '',
      attachments: [],
      reply: null,
      effectId: null,
      updatedAtEpochMilliseconds: 2,
    );
void main() {
  final scenarios =
      <
        String,
        ({LogicalAuthorityRevision? anchor, LogicalAuthorityRevision? fresh, LogicalDraftAuthorityAlignment expected})
      >{
        'same exact revision': (anchor: old, fresh: old, expected: LogicalDraftAuthorityAlignment.current),
        'persisted old epoch with stable tap authority': (
          anchor: live,
          fresh: live,
          expected: LogicalDraftAuthorityAlignment.refreshEpoch,
        ),
        'missing tap anchor': (anchor: null, fresh: live, expected: LogicalDraftAuthorityAlignment.missingFreeze),
        'missing current observation': (
          anchor: live,
          fresh: null,
          expected: LogicalDraftAuthorityAlignment.authorityChanged,
        ),
        'material authority changed': (
          anchor: live,
          fresh: const LogicalAuthorityRevision(certificateRevision: 'cert', authorityRevision: 'changed', epoch: 21),
          expected: LogicalDraftAuthorityAlignment.authorityChanged,
        ),
        'certificate changed': (
          anchor: live,
          fresh: const LogicalAuthorityRevision(
            certificateRevision: 'changed',
            authorityRevision: 'authority',
            epoch: 21,
          ),
          expected: LogicalDraftAuthorityAlignment.certificateChanged,
        ),
        'ABA during freeze': (
          anchor: live,
          fresh: const LogicalAuthorityRevision(certificateRevision: 'cert', authorityRevision: 'authority', epoch: 22),
          expected: LogicalDraftAuthorityAlignment.changedDuringFreeze,
        ),
      };
  for (final entry in scenarios.entries) {
    test(
      entry.key,
      () => expect(
        logicalDraftAuthorityAlignment(
          draft: draft(),
          frozenAuthority: entry.value.anchor,
          observedAuthority: entry.value.fresh,
        ),
        entry.value.expected,
      ),
    );
  }
  test('already current draft cannot conceal differing freeze anchor', () {
    expect(
      logicalDraftAuthorityAlignment(draft: draft(live), frozenAuthority: old, observedAuthority: live),
      LogicalDraftAuthorityAlignment.changedDuringFreeze,
    );
  });
  test('missing saved binding is never epoch-only', () {
    expect(
      logicalDraftAuthorityAlignment(draft: draft(null), frozenAuthority: live, observedAuthority: live),
      isNot(LogicalDraftAuthorityAlignment.refreshEpoch),
    );
  });
  test('refresh retains action/content/composition and provides exact consumption draft', () {
    final original = draft();
    var current = live;
    late final LogicalDraftIntentGuard guard;
    guard = LogicalDraftIntentGuard(
      frozenDraft: original,
      authorityAtFreeze: live,
      validateCurrent: () => null,
      composerIsCurrent: () => true,
      record: (_, _) {},
      validateAuthority: () => current.matchesDraft(guard.effectiveDraft!) ? null : 'AUTHORITY_CHANGED',
    );
    final rearmed = original.rearm(live, updatedAtEpochMilliseconds: 3);
    guard.acceptAuthorityRefresh(rearmed, live);
    guard.validateBeforeTransport();
    expect(guard.effectiveDraft, same(rearmed));
    expect(rearmed.actionId, original.actionId);
    expect(rearmed.contentFingerprint, original.contentFingerprint);
    expect(rearmed.compositionAuthorityEpoch, original.compositionAuthorityEpoch);
    current = const LogicalAuthorityRevision(certificateRevision: 'cert', authorityRevision: 'authority', epoch: 21);
    expect(guard.validateBeforeTransport, throwsA(isA<LogicalDraftIntentException>()));
  });
  for (final reason in [
    'CONTENT_CHANGED',
    'ATTACHMENT_INTENT_CHANGED',
    'OWNER_CHANGED',
    'GENERATION_CHANGED_EXTERNAL',
  ]) {
    test('$reason blocks alignment and leaves original intent bound', () {
      final original = draft();
      final guard = LogicalDraftIntentGuard(
        frozenDraft: original,
        authorityAtFreeze: live,
        validateCurrent: () => reason,
        composerIsCurrent: () => false,
        record: (_, _) {},
      );
      expect(
        () => guard.acceptAuthorityRefresh(original.rearm(live, updatedAtEpochMilliseconds: 3), live),
        throwsA(isA<LogicalDraftIntentException>()),
      );
      expect(guard.effectiveDraft, same(original));
      expect(guard.providerRequestStarted, false);
    });
  }
  test('changed action cannot be smuggled through refresh', () {
    final original = draft();
    final guard = LogicalDraftIntentGuard(
      frozenDraft: original,
      authorityAtFreeze: live,
      validateCurrent: () => null,
      composerIsCurrent: () => true,
      record: (_, _) {},
    );
    final changed = original
        .mergeUserIntent(
          text: 'new',
          subject: '',
          attachments: [],
          reply: null,
          effectId: null,
          updatedAtEpochMilliseconds: 3,
        )
        .rearm(live, updatedAtEpochMilliseconds: 4);
    expect(() => guard.acceptAuthorityRefresh(changed, live), throwsA(isA<LogicalDraftIntentException>()));
  });
  test('closed owner and already-invoked transport cannot gain new authority', () {
    for (final started in [false, true]) {
      final original = draft();
      final guard = LogicalDraftIntentGuard(
        frozenDraft: original,
        authorityAtFreeze: live,
        validateCurrent: () => null,
        composerIsCurrent: () => true,
        record: (_, _) {},
      );
      if (started) {
        guard.requestStarted();
      } else {
        guard.close();
      }
      expect(
        () => guard.acceptAuthorityRefresh(original.rearm(live, updatedAtEpochMilliseconds: 3), live),
        throwsA(isA<LogicalDraftIntentException>()),
      );
    }
  });
  test('device probe uses shared policy without modifying its input', () {
    final original = draft();
    final before = original.toJson();
    final report = logicalDraftAdmissionProbe(draft: original, authority: live, generation: 7, storageCoherent: true);
    expect(report['policyChecksPass'], true);
    expect(report['localAlignment'], 'refreshEpoch');
    expect(report['generation'], 7);
    expect(report['persistenceExercised'], false);
    expect(report['reservationExercised'], false);
    expect(report['transportExercised'], false);
    expect(original.toJson(), before);
  });
  test('probe reports live missing state independently of passing policy fixtures', () {
    final report = logicalDraftAdmissionProbe(draft: null, authority: null, generation: 0, storageCoherent: false);
    expect(report['policyChecksPass'], true);
    expect(report['localAlignment'], 'UNAVAILABLE');
    expect(report['storageCoherent'], false);
  });
  test('strictly empty intent excludes every meaningful draft field', () {
    final empty = LogicalDraft.create(logicalId: 'logical', nowEpochMilliseconds: 1, observedRevision: old);
    expect(empty.hasUserIntent, false);
    for (final value in ['text', 'subject', 'effect']) {
      final changed = empty.mergeUserIntent(
        text: value == 'text' ? ' ' : '',
        subject: value == 'subject' ? 'subject' : '',
        attachments: [],
        reply: null,
        effectId: value == 'effect' ? 'effect' : null,
        updatedAtEpochMilliseconds: 2,
      );
      expect(changed.hasUserIntent, true);
    }
    expect(
      empty
          .mergeUserIntent(
            text: '',
            subject: '',
            attachments: [const LogicalAttachmentIntent(intentId: 'a', name: 'a', size: 1, isRestorable: false)],
            reply: null,
            effectId: null,
            updatedAtEpochMilliseconds: 2,
          )
          .hasUserIntent,
      true,
    );
  });
}
