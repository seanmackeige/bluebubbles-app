import 'logical_draft.dart';
import 'logical_draft_authority_alignment.dart';
import 'logical_draft_intent_guard.dart';

/// Pure, bounded local checks. No persistence, provider, receipt or transport
/// dependency exists in this library. Synthetic intent exists only in memory.
Map<String, Object?> logicalDraftAdmissionProbe({
  required LogicalDraft? draft,
  required LogicalAuthorityRevision? authority,
  required int generation,
  required bool storageCoherent,
}) {
  const old = LogicalAuthorityRevision(
    certificateRevision: 'fixture-certificate',
    authorityRevision: 'fixture-authority',
    epoch: 101,
  );
  const current = LogicalAuthorityRevision(
    certificateRevision: 'fixture-certificate',
    authorityRevision: 'fixture-authority',
    epoch: 202,
  );
  final fixture = LogicalDraft.create(logicalId: 'fixture.logical', nowEpochMilliseconds: 1, observedRevision: old);
  final cases = <String, bool>{};
  LogicalDraftAuthorityAlignment classify(LogicalAuthorityRevision? frozen, LogicalAuthorityRevision? observed) =>
      logicalDraftAuthorityAlignment(draft: fixture, frozenAuthority: frozen, observedAuthority: observed);
  cases['epoch_only'] = classify(current, current) == LogicalDraftAuthorityAlignment.refreshEpoch;
  cases['already_current'] = classify(old, old) == LogicalDraftAuthorityAlignment.current;
  cases['missing_freeze_blocks'] = classify(null, current) == LogicalDraftAuthorityAlignment.missingFreeze;
  cases['missing_observation_blocks'] = classify(current, null) == LogicalDraftAuthorityAlignment.authorityChanged;
  cases['aba_blocks'] =
      classify(
        current,
        const LogicalAuthorityRevision(
          certificateRevision: 'fixture-certificate',
          authorityRevision: 'fixture-authority',
          epoch: 204,
        ),
      ) ==
      LogicalDraftAuthorityAlignment.changedDuringFreeze;
  cases['material_change_blocks'] =
      classify(
        current,
        const LogicalAuthorityRevision(
          certificateRevision: 'fixture-certificate',
          authorityRevision: 'changed',
          epoch: 203,
        ),
      ) ==
      LogicalDraftAuthorityAlignment.authorityChanged;
  cases['certificate_change_blocks'] =
      classify(
        current,
        const LogicalAuthorityRevision(
          certificateRevision: 'changed',
          authorityRevision: 'fixture-authority',
          epoch: 203,
        ),
      ) ==
      LogicalDraftAuthorityAlignment.certificateChanged;
  String? humanChange;
  final gate = LogicalDraftIntentGuard(
    frozenDraft: fixture,
    authorityAtFreeze: current,
    validateCurrent: () => humanChange,
    composerIsCurrent: () => humanChange == null,
    record: (_, _) {},
  );
  final aligned = fixture.rearm(current, updatedAtEpochMilliseconds: 2);
  try {
    gate.acceptAuthorityRefresh(aligned, current);
    cases['same_action_preserved'] = gate.effectiveDraft?.actionId == fixture.actionId;
    humanChange = 'CONTENT_CHANGED';
    try {
      gate.validateBeforeTransport();
      cases['human_change_blocks'] = false;
    } on LogicalDraftIntentException catch (e) {
      cases['human_change_blocks'] = e.reason == 'CONTENT_CHANGED';
    }
  } catch (_) {
    cases['same_action_preserved'] = false;
    cases['human_change_blocks'] = false;
  }
  return <String, Object?>{
    'schema': 'LOGICAL_DRAFT_PREFLIGHT_V1',
    'scope': 'LOCAL_SNAPSHOT_AND_SHARED_POLICY_ONLY',
    'policyChecksPass': cases.values.every((passed) => passed),
    'policyCases': cases,
    'storageCoherent': storageCoherent,
    'draftPresent': draft != null,
    'emptyIntent': draft == null
        ? null
        : draft.text.isEmpty &&
              draft.subject.isEmpty &&
              draft.attachments.isEmpty &&
              draft.reply == null &&
              draft.effectId == null,
    'nextNonemptyIntentUsesCurrentAuthority': storageCoherent && draft?.hasUserIntent == false && authority != null,
    'generation': generation,
    'draftAction': draft?.actionId,
    'contentFingerprint': draft?.contentFingerprint,
    'draftContentRevision': draft?.contentRevision,
    'draftClass': draft?.metadataClass.diagnosticName,
    'logicalFingerprint': draft?.logicalFingerprint,
    'confirmationRevision': draft?.confirmation?.revision,
    'confirmationInvalidated': draft?.confirmation?.invalidated,
    'compositionCertificate': draft?.compositionCertificateRevision,
    'compositionAuthority': draft?.compositionAuthorityRevision,
    'compositionEpoch': draft?.compositionAuthorityEpoch,
    'sendAdmissionResult': draft?.metadataClass == LogicalDraftMetadataClass.legacyUnboundDraft
        ? 'BLOCKED_MISSING_METADATA'
        : 'NOT_EXERCISED',
    'draftCertificate': draft?.observedCertificateRevision,
    'liveCertificate': authority?.certificateRevision,
    'draftAuthority': draft?.observedAuthorityRevision,
    'liveAuthority': authority?.authorityRevision,
    'draftEpoch': draft?.observedAuthorityEpoch,
    'liveEpoch': authority?.epoch,
    'localAlignment': draft == null || !storageCoherent
        ? 'UNAVAILABLE'
        : logicalDraftAuthorityAlignment(draft: draft, frozenAuthority: authority, observedAuthority: authority).name,
    'freshProviderObservationExercised': false,
    'persistenceExercised': false,
    'reservationExercised': false,
    'transportExercised': false,
  };
}
