import 'logical_draft.dart';

enum LogicalDraftAuthorityAlignment {
  current,
  refreshEpoch,
  certificateChanged,
  authorityChanged,
  missingFreeze,
  changedDuringFreeze,
}

/// A persisted epoch may be old, but the authority captured for THIS intent
/// must survive the fresh provider observation byte-for-byte, including epoch.
/// This never substitutes for provider evidence, replay admission or final fencing.
LogicalDraftAuthorityAlignment logicalDraftAuthorityAlignment({
  required LogicalDraft draft,
  required LogicalAuthorityRevision? frozenAuthority,
  required LogicalAuthorityRevision? observedAuthority,
}) {
  final fresh = observedAuthority;
  if (fresh == null || fresh.certificateRevision.isEmpty || fresh.authorityRevision.isEmpty) {
    return LogicalDraftAuthorityAlignment.authorityChanged;
  }
  if (draft.observedCertificateRevision != fresh.certificateRevision) {
    return LogicalDraftAuthorityAlignment.certificateChanged;
  }
  if (draft.observedAuthorityRevision != fresh.authorityRevision) {
    return LogicalDraftAuthorityAlignment.authorityChanged;
  }
  if (frozenAuthority != null && !sameLogicalAuthorityRevision(frozenAuthority, fresh)) {
    return LogicalDraftAuthorityAlignment.changedDuringFreeze;
  }
  if (fresh.matchesDraft(draft)) return LogicalDraftAuthorityAlignment.current;
  if (frozenAuthority == null || draft.observedAuthorityEpoch == null) {
    return LogicalDraftAuthorityAlignment.missingFreeze;
  }
  return LogicalDraftAuthorityAlignment.refreshEpoch;
}

bool sameLogicalAuthorityRevision(LogicalAuthorityRevision? left, LogicalAuthorityRevision? right) =>
    left != null &&
    right != null &&
    left.certificateRevision == right.certificateRevision &&
    left.authorityRevision == right.authorityRevision &&
    left.epoch == right.epoch;
