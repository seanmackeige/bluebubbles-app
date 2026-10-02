import 'dart:convert';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:bluebubbles/services/ui/chat/logical_certificate_advancement_transaction.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_certificate_ledger.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry_binding.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/logical_read_certificate_fixture.dart';

void main() {
  tearDown(LogicalConversationViewPolicy.resetRuntimeCertificateForTesting);

  group('multi-certificate authority ledger', () {
    test('binds two disjoint authorities while the Build 99 alias remains banked', () {
      final validButStaleLegacy = encodeLegacyBuild99ReadCertificate(
        bindBankedReadFixture(firstRow: 701, secondRow: 702, presentationRow: 703),
      );
      final fixture = _fixture();

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: fixture.allBindings,
          persistedLedgerJson: fixture.ledgerJson,
          legacyCertificateJson: validButStaleLegacy,
        ),
        isTrue,
      );

      expect(LogicalConversationViewPolicy.certificateLedgerValid, isTrue);
      expect(LogicalConversationViewPolicy.certificateLedgerCorrupt, isFalse);
      expect(LogicalConversationViewPolicy.allRuntimeCertificatesAvailable, isTrue);
      expect(LogicalConversationViewPolicy.activeCertificates, hasLength(2));
      expect(
        LogicalConversationViewPolicy.activeCertificate.id,
        LogicalConversationViewPolicy.bankedReadTrustAnchor.id,
      );
      expect(LogicalConversationViewPolicy.approvedSourceRowIds, <int>{
        readFixtureFirstRow,
        readFixtureSecondRow,
        readFixturePresentationRow,
        301,
        302,
      });
      expect(LogicalConversationViewPolicy.membershipProofFor(301), isNotNull);
      expect(LogicalConversationViewPolicy.membershipProofFor(999), isNull);

      final projected = LogicalConversationViewPolicy.projectConversationList<int>(<int>[
        readFixtureFirstRow,
        readFixtureSecondRow,
        readFixturePresentationRow,
        301,
        302,
        999,
      ], (rowId) => rowId);
      expect(projected, <int>[readFixturePresentationRow, 302, 999]);
      expect(fixture.ledgerJson, isNot(contains('sourceChatRowId')));
      expect(fixture.ledgerJson, isNot(contains('alpha-provider-1')));
    });

    test('partial member availability preserves ledger identity and fails only that runtime binding closed', () {
      final fixture = _fixture();
      final partial = fixture.allBindings.where((binding) => binding.sourceChatRowId != 302);

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: partial,
          persistedLedgerJson: fixture.ledgerJson,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.activeCertificates, hasLength(1));
      expect(LogicalConversationViewPolicy.certificateLedgerLogicalIds, contains(fixture.syntheticLogicalId));
      expect(LogicalConversationViewPolicy.unavailableCertificateLogicalIds, <LogicalConversationId>{
        fixture.syntheticLogicalId,
      });
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(301), isTrue);
      expect(
        LogicalConversationViewPolicy.trustedLogicalIdForSourceBinding(
          sourceChatRowId: 301,
          sourceChatGuid: 'alpha-provider-1',
        ),
        fixture.syntheticLogicalId,
      );
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(302), isFalse);
      expect(LogicalConversationViewPolicy.membershipProofFor(301), isNull);
      final partialRegistry = LogicalConversationRegistryBinding.bindAuthorities(
        authorities: LogicalConversationViewPolicy.activeAuthorities,
        physicalChats: partial,
      );
      final partialEntry = partialRegistry.entryForLogicalId(fixture.syntheticLogicalId)!;
      expect(partialEntry.members, hasLength(2));
      expect(partialEntry.runtimePhysicalRefs, hasLength(1));
      expect(partialEntry.sourceChatRowIds, <int>{301});
      expect(partialRegistry.projectConversationList<int>(<int>[301, 999], (rowId) => rowId), <int>[301, 999]);
      final stableCertifiedRefs = partialEntry.certifiedMemberRefs;
      final stableRegistryFingerprint = partialRegistry.stableFingerprint;

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: fixture.allBindings,
          persistedLedgerJson: fixture.ledgerJson,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.certificateLedgerLogicalIds, contains(fixture.syntheticLogicalId));
      expect(LogicalConversationViewPolicy.unavailableCertificateLogicalIds, isEmpty);
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(301), isTrue);
      expect(
        LogicalConversationViewPolicy.trustedLogicalIdForSourceBinding(
          sourceChatRowId: 302,
          sourceChatGuid: 'alpha-provider-2',
        ),
        fixture.syntheticLogicalId,
      );
      final reboundRegistry = LogicalConversationRegistryBinding.bindAuthorities(
        authorities: LogicalConversationViewPolicy.activeAuthorities,
        physicalChats: fixture.allBindings,
      );
      final reboundEntry = reboundRegistry.entryForLogicalId(fixture.syntheticLogicalId)!;
      expect(reboundEntry.certifiedMemberRefs, stableCertifiedRefs);
      expect(reboundRegistry.stableFingerprint, stableRegistryFingerprint);
      expect(reboundEntry.runtimePhysicalRefs, hasLength(2));
      expect(reboundEntry.presentationMember.sourceChatRowId, 302);
    });

    test('corrupt V2 ledger fails closed without falling back to a valid V1 singleton', () {
      final legacyCertificate = bindBankedReadFixture();
      final legacyJson = encodeLegacyBuild99ReadCertificate(legacyCertificate);
      LogicalConversationViewPolicy.resetRuntimeCertificateForTesting();

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: bankedReadFixtureBindings(),
          persistedLedgerJson: jsonEncode(<String, dynamic>{
            'schema': logicalConversationCertificateLedgerSchema,
            'entries': <String, dynamic>{},
            'revision': '0000000000000000000000000000000000000000000000000000000000000000',
          }),
          legacyCertificateJson: legacyJson,
        ),
        isFalse,
      );
      expect(LogicalConversationViewPolicy.certificateLedgerValid, isFalse);
      expect(LogicalConversationViewPolicy.certificateLedgerCorrupt, isTrue);
      expect(LogicalConversationViewPolicy.activeCertificates, isEmpty);
      expect(LogicalConversationViewPolicy.approvedSourceRowIds, isEmpty);

      // A corrupt authoritative V2 ledger has lost the only trustworthy
      // protection index. Unknown runtime rows must therefore fail closed
      // rather than being misclassified as ordinary mutable conversations.
      final service = ChatsService();
      final unknownRuntimeChat = Chat(guid: 'unknown-after-corrupt-v2', chatIdentifier: 'unknown-after-corrupt-v2');
      expect(service.isPotentialLogicalSource(unknownRuntimeChat), isTrue);
      expect(service.canApplyConversationLocalStateMutation(unknownRuntimeChat), isFalse);
    });

    test('V1 singleton migrates idempotently to one row-free banked ledger entry', () {
      final legacyCertificate = bindBankedReadFixture(firstRow: 71, secondRow: 72, presentationRow: 73);
      final legacyJson = encodeLegacyBuild99ReadCertificate(legacyCertificate);
      LogicalConversationViewPolicy.resetRuntimeCertificateForTesting();
      final bindings = bankedReadFixtureBindings(firstRow: 171, secondRow: 172, presentationRow: 173);

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: bindings,
          persistedLedgerJson: null,
          legacyCertificateJson: legacyJson,
        ),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.certificateLedgerMigrationPending, isTrue);
      expect(LogicalConversationViewPolicy.activeCertificate.sourceChatRowIds, <int>{171, 172, 173});
      final migrated = LogicalConversationViewPolicy.encodeActiveCertificateLedger();
      final decoded = LogicalConversationCertificateLedger.decode(migrated);
      expect(decoded.records, hasLength(1));
      expect(migrated, isNot(contains('RowId')));
      LogicalConversationViewPolicy.markCertificateLedgerMigrationPersisted();
      expect(LogicalConversationViewPolicy.certificateLedgerMigrationPending, isFalse);

      LogicalConversationViewPolicy.resetRuntimeCertificateForTesting();
      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: bindings,
          persistedLedgerJson: migrated,
          legacyCertificateJson: '{stale-legacy-is-ignored',
        ),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.certificateLedgerMigrationPending, isFalse);
      expect(LogicalConversationViewPolicy.encodeActiveCertificateLedger(), migrated);
    });

    test('cross-entry provider fingerprint and certified-ref collision is rejected before binding', () {
      final banked = bindBankedReadFixture();
      final collisionFingerprint =
          LogicalConversationViewPolicy.bankedReadTrustAnchor.members.first.sourceChatGuidSha256;
      final colliding = _syntheticCertificate('synthetic-collision', <int, String>{
        301: collisionFingerprint,
        302: _providerFingerprint('collision-other'),
      }, 302);

      expect(
        () => LogicalConversationViewPolicy.encodeCertificateLedger(<LogicalConversationCertificateAuthority>[
          _bankedAuthority(banked),
          LogicalConversationCertificateAuthority.fromBoundCertificate(colliding),
        ]),
        throwsFormatException,
      );
    });

    test('cross-entry runtime ROWID collision invalidates the entire ledger', () {
      final fixture = _fixture();
      final collidingBindings = <LogicalConversationPhysicalChatBinding>[
        ...bankedReadFixtureBindings(),
        _binding(301, fixture.syntheticFingerprints[301]!),
        _binding(readFixtureFirstRow, fixture.syntheticFingerprints[302]!),
      ];

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: collidingBindings,
          persistedLedgerJson: fixture.ledgerJson,
          legacyCertificateJson: null,
        ),
        isFalse,
      );
      expect(LogicalConversationViewPolicy.certificateLedgerValid, isFalse);
      expect(LogicalConversationViewPolicy.certificateLedgerCorrupt, isTrue);
      expect(LogicalConversationViewPolicy.activeCertificates, isEmpty);
      expect(LogicalConversationViewPolicy.approvedSourceRowIds, isEmpty);
    });

    test('certificate advancement replaces only its matching ledger entry', () {
      final fixture = _fixture();
      final extended = _syntheticCertificate(fixture.syntheticCertificate.id, <int, String>{
        ...fixture.syntheticFingerprints,
        303: _providerFingerprint('alpha-provider-3'),
      }, 302);
      final advancedAuthority = LogicalConversationCertificateAuthority.fromBoundCertificate(
        extended,
        trustedCertificate: fixture.syntheticCertificate,
      );
      expect(advancedAuthority.logicalId, fixture.syntheticLogicalId);
      expect(() => LogicalConversationViewPolicy.encodeReconciledRuntimeCertificate(extended), throwsFormatException);
      final originalLedger = LogicalConversationCertificateLedger.decode(fixture.ledgerJson);
      final originalBankedEnvelope = jsonEncode(
        originalLedger.recordFor(LogicalConversationViewPolicy.bankedApplicationLogicalId)!.certificateEnvelope,
      );

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: fixture.allBindings,
          persistedLedgerJson: fixture.ledgerJson,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      final encodedSynthetic = LogicalConversationViewPolicy.encodeReconciledRuntimeCertificate(extended);
      final advancedLedgerJson = LogicalConversationViewPolicy.mergeRuntimeCertificateIntoLedger(
        persistedLedgerJson: fixture.ledgerJson,
        runtimeCertificateJson: encodedSynthetic,
      );
      final advancedLedger = LogicalConversationCertificateLedger.decode(advancedLedgerJson);
      expect(
        jsonEncode(
          advancedLedger.recordFor(LogicalConversationViewPolicy.bankedApplicationLogicalId)!.certificateEnvelope,
        ),
        originalBankedEnvelope,
      );

      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: <LogicalConversationPhysicalChatBinding>[
            ...fixture.allBindings,
            _binding(303, _providerFingerprint('alpha-provider-3')),
          ],
          persistedLedgerJson: advancedLedgerJson,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.certificateForLogicalId(fixture.syntheticLogicalId)!.sourceChatRowIds, <int>{
        301,
        302,
        303,
      });
      expect(LogicalConversationViewPolicy.activeCertificate.sourceChatRowIds, <int>{
        readFixtureFirstRow,
        readFixtureSecondRow,
        readFixturePresentationRow,
      });
    });

    test('in-memory reconciliation advances only the nominated authority', () {
      final fixture = _fixture();
      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: fixture.allBindings,
          persistedLedgerJson: fixture.ledgerJson,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      final bankedRevision = LogicalConversationViewPolicy.activeCertificate.revision;
      final current = LogicalConversationViewPolicy.certificateForLogicalId(fixture.syntheticLogicalId)!;
      final extended = _syntheticCertificate(fixture.syntheticCertificate.id, <int, String>{
        ...fixture.syntheticFingerprints,
        303: _providerFingerprint('alpha-provider-3'),
      }, 302);

      expect(
        LogicalConversationViewPolicy.activateReconciledCertificate(
          LogicalConversationCertificateReconciliation(
            certificate: extended,
            decisions: const <LogicalConversationCandidateDecision>[],
          ),
          expectedRevision: current.revision,
        ),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.activeCertificate.revision, bankedRevision);
      expect(LogicalConversationViewPolicy.certificateForLogicalId(fixture.syntheticLogicalId)!.sourceChatRowIds, <int>{
        301,
        302,
        303,
      });
      final persisted = LogicalConversationCertificateLedger.decode(
        LogicalConversationViewPolicy.encodeActiveCertificateLedger(),
      );
      expect(persisted.records, hasLength(2));

      final refreshedRegistry = LogicalConversationRegistryBinding.bindAuthorities(
        authorities: LogicalConversationViewPolicy.activeAuthorities,
        physicalChats: <LogicalConversationPhysicalChatBinding>[
          ...fixture.allBindings,
          _binding(303, _providerFingerprint('alpha-provider-3')),
        ],
      );
      final refreshed = refreshedRegistry.entryForLogicalId(fixture.syntheticLogicalId)!;
      expect(refreshed.members, hasLength(3));
      expect(refreshed.sourceChatRowIds, <int>{301, 302, 303});
      expect(refreshedRegistry.projectConversationList<int>(<int>[301, 302, 303], (rowId) => rowId), <int>[302]);
    });

    test('concurrent different-authority advancements serialize without losing either entry', () async {
      final fixture = _fixture();
      final betaFingerprints = <int, String>{
        401: _providerFingerprint('beta-provider-1'),
        402: _providerFingerprint('beta-provider-2'),
      };
      final beta = _syntheticCertificate('synthetic-human-beta', betaFingerprints, 402);
      var durableLedger =
          LogicalConversationViewPolicy.encodeCertificateLedger(<LogicalConversationCertificateAuthority>[
            _bankedAuthority(bindBankedReadFixture()),
            LogicalConversationCertificateAuthority.fromBoundCertificate(fixture.syntheticCertificate),
            LogicalConversationCertificateAuthority.fromBoundCertificate(beta),
          ]);
      final bindings = <LogicalConversationPhysicalChatBinding>[
        ...fixture.allBindings,
        for (final entry in betaFingerprints.entries) _binding(entry.key, entry.value),
      ];
      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: bindings,
          persistedLedgerJson: durableLedger,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      final alphaExtended = _syntheticCertificate(fixture.syntheticCertificate.id, <int, String>{
        ...fixture.syntheticFingerprints,
        303: _providerFingerprint('alpha-provider-3'),
      }, 302);
      final betaExtended = _syntheticCertificate(beta.id, <int, String>{
        ...betaFingerprints,
        403: _providerFingerprint('beta-provider-3'),
      }, 402);
      final alphaRuntime = LogicalConversationViewPolicy.encodeReconciledRuntimeCertificate(alphaExtended);
      final betaRuntime = LogicalConversationViewPolicy.encodeReconciledRuntimeCertificate(betaExtended);
      final queue = LogicalCertificateAdvancementTransactionQueue();
      var activeTransactions = 0;
      var maximumActiveTransactions = 0;

      Future<LogicalCertificateAdvancementResult> commit(String runtime, String expectedRevision) => queue.commit(
        runtimeCertificateJson: runtime,
        expectedPersistedCertificateRevision: expectedRevision,
        loadAuthority: () async {
          activeTransactions += 1;
          if (activeTransactions > maximumActiveTransactions) maximumActiveTransactions = activeTransactions;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return LogicalCertificateAuthorityState(ledgerJson: durableLedger, legacyCertificateJson: null);
        },
        persistAuthority: (ledger, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          durableLedger = ledger;
        },
        activateAuthority: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          activeTransactions -= 1;
          return true;
        },
      );

      final results = await Future.wait(<Future<LogicalCertificateAdvancementResult>>[
        commit(
          alphaRuntime,
          LogicalConversationViewPolicy.persistedRevisionForBoundCertificate(fixture.syntheticCertificate),
        ),
        commit(betaRuntime, LogicalConversationViewPolicy.persistedRevisionForBoundCertificate(beta)),
      ]);
      expect(results.every((result) => result.committed), isTrue);
      expect(maximumActiveTransactions, 1);
      expect(
        LogicalConversationViewPolicy.certificateRevisionForPersistedAuthority(
          persistedLedgerJson: durableLedger,
          legacyCertificateJson: null,
          logicalId: fixture.syntheticLogicalId,
        ),
        LogicalConversationViewPolicy.persistedRevisionForBoundCertificate(alphaExtended),
      );
      expect(
        LogicalConversationViewPolicy.certificateRevisionForPersistedAuthority(
          persistedLedgerJson: durableLedger,
          legacyCertificateJson: null,
          logicalId: LogicalConversationId.certified(beta.id),
        ),
        LogicalConversationViewPolicy.persistedRevisionForBoundCertificate(betaExtended),
      );
    });

    test('concurrent stale same-authority advancement performs one physical commit', () async {
      final fixture = _fixture();
      var durableLedger = fixture.ledgerJson;
      expect(
        LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: fixture.allBindings,
          persistedLedgerJson: durableLedger,
          legacyCertificateJson: null,
        ),
        isTrue,
      );
      final extended = _syntheticCertificate(fixture.syntheticCertificate.id, <int, String>{
        ...fixture.syntheticFingerprints,
        303: _providerFingerprint('alpha-provider-3'),
      }, 302);
      final runtime = LogicalConversationViewPolicy.encodeReconciledRuntimeCertificate(extended);
      final queue = LogicalCertificateAdvancementTransactionQueue();
      var persistCount = 0;
      var activationCount = 0;
      Future<LogicalCertificateAdvancementResult> commit() => queue.commit(
        runtimeCertificateJson: runtime,
        expectedPersistedCertificateRevision: LogicalConversationViewPolicy.persistedRevisionForBoundCertificate(
          fixture.syntheticCertificate,
        ),
        loadAuthority: () async =>
            LogicalCertificateAuthorityState(ledgerJson: durableLedger, legacyCertificateJson: null),
        persistAuthority: (ledger, _) async {
          persistCount += 1;
          durableLedger = ledger;
        },
        activateAuthority: (_) async {
          activationCount += 1;
          return true;
        },
      );
      final results = await Future.wait(<Future<LogicalCertificateAdvancementResult>>[commit(), commit()]);
      expect(results.where((result) => result.committed), hasLength(1));
      expect(
        results.where((result) => result.disposition == LogicalCertificateAdvancementDisposition.staleRevision),
        hasLength(1),
      );
      expect(persistCount, 1);
      expect(activationCount, 1);
    });
  });
}

_LedgerFixture _fixture() {
  final bankedCertificate = bindBankedReadFixture();
  final fingerprints = <int, String>{
    301: _providerFingerprint('alpha-provider-1'),
    302: _providerFingerprint('alpha-provider-2'),
  };
  final synthetic = _syntheticCertificate('synthetic-human-alpha', fingerprints, 302);
  final ledger = LogicalConversationViewPolicy.encodeCertificateLedger(<LogicalConversationCertificateAuthority>[
    _bankedAuthority(bankedCertificate),
    LogicalConversationCertificateAuthority.fromBoundCertificate(synthetic),
  ]);
  return _LedgerFixture(
    ledgerJson: ledger,
    syntheticCertificate: synthetic,
    syntheticFingerprints: fingerprints,
    allBindings: <LogicalConversationPhysicalChatBinding>[
      ...bankedReadFixtureBindings(),
      for (final entry in fingerprints.entries) _binding(entry.key, entry.value),
    ],
  );
}

LogicalConversationCertificateAuthority _bankedAuthority(LogicalConversationReadCertificate certificate) =>
    LogicalConversationCertificateAuthority(
      trustedAnchor: LogicalConversationViewPolicy.bankedReadTrustAnchor,
      certificate: LogicalConversationBankedCertificateTrustAnchor.fromBoundCertificate(certificate),
    );

LogicalConversationReadCertificate _syntheticCertificate(
  String id,
  Map<int, String> fingerprints,
  int presentationRow,
) {
  final rows = fingerprints.keys.toList(growable: false)..sort();
  return LogicalConversationReadCertificate(
    schema: logicalConversationReadCertificateSchema,
    id: id,
    presentationSourceChatRowId: presentationRow,
    members: <LogicalConversationMemberProof>[
      for (final row in rows)
        LogicalConversationMemberProof(
          sourceChatRowId: row,
          sourceChatGuidHmacSha256: '',
          sourceChatGuidSha256: fingerprints[row]!,
          admissionReceiptCommit: '',
          admissionEvidenceSha256: sha256.convert(utf8.encode('independent-evidence-$id-$row')).toString(),
          evidence: const <LogicalConversationMemberEvidenceKind>{
            LogicalConversationMemberEvidenceKind.stableProviderBackedAppleIdentity,
            LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
            LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
            LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
            LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
          },
          pairwiseComparedSourceRowIds: rows.where((peer) => peer != row).toSet(),
          directRelationshipPeerRowIds: <int>{rows.firstWhere((peer) => peer != row)},
          minimumStructuredRelationshipCount: 1,
          explanation: 'Independent synthetic privacy-safe certificate evidence.',
        ),
    ],
  );
}

String _providerFingerprint(String seed) =>
    sha256.convert(utf8.encode('logical-provider-guid-v1\u0000$seed')).toString();

LogicalConversationPhysicalChatBinding _binding(int row, String fingerprint) =>
    LogicalConversationPhysicalChatBinding.fromGuidSha256(sourceChatRowId: row, sourceChatGuidSha256: fingerprint);

class _LedgerFixture {
  const _LedgerFixture({
    required this.ledgerJson,
    required this.syntheticCertificate,
    required this.syntheticFingerprints,
    required this.allBindings,
  });

  final String ledgerJson;
  final LogicalConversationReadCertificate syntheticCertificate;
  final Map<int, String> syntheticFingerprints;
  final List<LogicalConversationPhysicalChatBinding> allBindings;

  LogicalConversationId get syntheticLogicalId => LogicalConversationId.certified(syntheticCertificate.id);
}
