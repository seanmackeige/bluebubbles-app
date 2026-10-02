import 'package:bluebubbles/services/ui/chat/logical_mutation_protection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical mutation protection', () {
    test('ordinary source remains mutable only when every protection signal is absent', () {
      final decision = classifyLogicalMutationProtection(
        authoritativeCertificateLedgerCorrupt: false,
        certifiedSource: false,
        quarantinedCandidate: false,
        bankedGenerationCandidate: false,
      );

      expect(decision.isProtected, isFalse);
      expect(decision.reason, LogicalMutationProtectionReason.none);
    });

    test('certified, quarantined, and pre-nomination generation candidates are protected', () {
      for (final caseValue in <({bool certified, bool quarantined, bool banked})>[
        (certified: true, quarantined: false, banked: false),
        (certified: false, quarantined: true, banked: false),
        (certified: false, quarantined: false, banked: true),
      ]) {
        final decision = classifyLogicalMutationProtection(
          authoritativeCertificateLedgerCorrupt: false,
          certifiedSource: caseValue.certified,
          quarantinedCandidate: caseValue.quarantined,
          bankedGenerationCandidate: caseValue.banked,
        );
        expect(decision.isProtected, isTrue);
      }
    });

    test('corrupt authoritative V2 is a global fail-closed decision', () {
      for (var mask = 0; mask < 8; mask++) {
        final decision = classifyLogicalMutationProtection(
          authoritativeCertificateLedgerCorrupt: true,
          certifiedSource: mask & 1 != 0,
          quarantinedCandidate: mask & 2 != 0,
          bankedGenerationCandidate: mask & 4 != 0,
        );

        expect(decision.isProtected, isTrue);
        expect(decision.reason, LogicalMutationProtectionReason.authoritativeCertificateLedgerCorrupt);
      }
    });

    test('classification precedence is deterministic for overlapping evidence', () {
      expect(
        classifyLogicalMutationProtection(
          authoritativeCertificateLedgerCorrupt: false,
          certifiedSource: true,
          quarantinedCandidate: true,
          bankedGenerationCandidate: true,
        ).reason,
        LogicalMutationProtectionReason.certifiedSource,
      );
      expect(
        classifyLogicalMutationProtection(
          authoritativeCertificateLedgerCorrupt: false,
          certifiedSource: false,
          quarantinedCandidate: true,
          bankedGenerationCandidate: true,
        ).reason,
        LogicalMutationProtectionReason.quarantinedCandidate,
      );
    });
  });
}
