import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_source_provenance.dart';
import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active and first-frame protected candidates cannot leak into search', () {
    expect(
      admitsLogicalSearchSource(isPotentialLogicalSource: true, isApprovedLogicalSource: false, candidatePhase: null),
      isFalse,
    );
    for (final phase in <LogicalCandidateQuarantinePhase>[
      LogicalCandidateQuarantinePhase.nominated,
      LogicalCandidateQuarantinePhase.reconciling,
      LogicalCandidateQuarantinePhase.certified,
    ]) {
      expect(
        admitsLogicalSearchSource(
          isPotentialLogicalSource: true,
          isApprovedLogicalSource: false,
          candidatePhase: phase,
        ),
        isFalse,
      );
    }
  });

  test('terminal candidates and certified members have one visible search identity', () {
    for (final phase in <LogicalCandidateQuarantinePhase>[
      LogicalCandidateQuarantinePhase.rejected,
      LogicalCandidateQuarantinePhase.expiredVisible,
    ]) {
      expect(
        admitsLogicalSearchSource(
          isPotentialLogicalSource: true,
          isApprovedLogicalSource: false,
          candidatePhase: phase,
        ),
        isTrue,
      );
    }
    expect(
      admitsLogicalSearchSource(isPotentialLogicalSource: true, isApprovedLogicalSource: true, candidatePhase: null),
      isTrue,
    );
  });
}
