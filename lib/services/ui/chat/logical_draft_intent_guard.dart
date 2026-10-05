import 'logical_draft.dart';
import 'logical_draft_authority_alignment.dart';

/// Same-owner fence: final semantic check and HTTP API invocation cannot yield.
class LogicalDraftIntentGuard {
  LogicalDraftIntentGuard({
    required this.validateCurrent,
    required this.record,
    required this.composerIsCurrent,
    this.validateAuthority,
    this.frozenDraft,
    this.authorityAtFreeze,
  });
  final String? Function() validateCurrent;
  final String? Function()? validateAuthority;
  final bool Function() composerIsCurrent;
  final void Function(String result, bool providerRequestStarted) record;
  final LogicalDraft? frozenDraft;
  final LogicalAuthorityRevision? authorityAtFreeze;
  LogicalDraft? _refreshedDraft;
  LogicalDraft? get effectiveDraft => _refreshedDraft ?? frozenDraft;

  void acceptAuthorityRefresh(LogicalDraft refreshed, LogicalAuthorityRevision observed) {
    check();
    final original = frozenDraft;
    if (providerRequestStarted ||
        _refreshedDraft != null ||
        original == null ||
        logicalDraftAuthorityAlignment(
              draft: original,
              frozenAuthority: authorityAtFreeze,
              observedAuthority: observed,
            ) !=
            LogicalDraftAuthorityAlignment.refreshEpoch ||
        refreshed.actionId != original.actionId ||
        refreshed.contentFingerprint != original.contentFingerprint ||
        refreshed.logicalId != original.logicalId ||
        !observed.matchesDraft(refreshed)) {
      _reject('AUTHORITY_CHANGED');
    }
    _refreshedDraft = refreshed;
    record('AUTHORITY_EPOCH_REFRESHED_EXPECTED_INTERNAL', false);
  }

  bool _closed = false;
  bool providerRequestStarted = false;
  bool draftWasConsumed = false;
  String? blockedReason;
  bool get composerStillCurrent => !_closed && composerIsCurrent();
  void check() {
    // First HTTP invocation commits the frozen batch. Subsequent human edits
    // are a new draft, preserved on completion; authority still gates each part.
    if (providerRequestStarted) return;
    _reject(_closed ? 'OWNER_CHANGED' : validateCurrent());
  }

  void validateBeforeTransport() {
    check();
    _reject(validateAuthority?.call());
  }

  void _reject(String? reason) {
    if (reason == null) return;
    blockedReason = reason;
    record(reason, providerRequestStarted);
    throw LogicalDraftIntentException(reason);
  }

  void requestStarted() {
    providerRequestStarted = true;
    record('HTTP_API_INVOKED', true);
  }

  void draftConsumed() {
    draftWasConsumed = true;
    record('DRAFT_CONSUMED', providerRequestStarted);
  }

  void close() => _closed = true;
}

class LogicalDraftIntentException implements Exception {
  const LogicalDraftIntentException(this.reason);
  final String reason;
  @override
  String toString() => 'LOGICAL_DRAFT_INTENT_BLOCKED:$reason';
}
