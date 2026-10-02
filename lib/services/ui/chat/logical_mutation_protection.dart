const logicalMutationProtectionContract = 'LOGICAL_MUTATION_PROTECTION_V1_FAIL_CLOSED';

/// Closed reasons why a physical conversation must not use ordinary mutation
/// semantics. This type intentionally contains no provider coordinates or
/// participant data.
enum LogicalMutationProtectionReason {
  none,
  authoritativeCertificateLedgerCorrupt,
  certifiedSource,
  quarantinedCandidate,
  bankedGenerationCandidate,
}

class LogicalMutationProtection {
  const LogicalMutationProtection(this.reason);

  final LogicalMutationProtectionReason reason;

  bool get isProtected => reason != LogicalMutationProtectionReason.none;
}

/// Produces one deterministic fail-closed decision from already-qualified
/// evidence. An authoritative-ledger failure dominates every narrower source
/// classification because its affected physical member set cannot be trusted.
LogicalMutationProtection classifyLogicalMutationProtection({
  required bool authoritativeCertificateLedgerCorrupt,
  required bool certifiedSource,
  required bool quarantinedCandidate,
  required bool bankedGenerationCandidate,
}) {
  if (authoritativeCertificateLedgerCorrupt) {
    return const LogicalMutationProtection(LogicalMutationProtectionReason.authoritativeCertificateLedgerCorrupt);
  }
  if (certifiedSource) {
    return const LogicalMutationProtection(LogicalMutationProtectionReason.certifiedSource);
  }
  if (quarantinedCandidate) {
    return const LogicalMutationProtection(LogicalMutationProtectionReason.quarantinedCandidate);
  }
  if (bankedGenerationCandidate) {
    return const LogicalMutationProtection(LogicalMutationProtectionReason.bankedGenerationCandidate);
  }
  return const LogicalMutationProtection(LogicalMutationProtectionReason.none);
}
