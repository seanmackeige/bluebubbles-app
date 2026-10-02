import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry_binding.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('multi logical conversation registry', () {
    test('two certified conversations retain disjoint deterministic reverse lookup', () {
      final fixture = _registryFixture();

      expect(fixture.registry.entries, hasLength(2));
      expect(fixture.registry.logicalIdForPhysicalRef(fixture.alphaRefs.first), fixture.alphaId);
      expect(fixture.registry.logicalIdForPhysicalRef(fixture.betaRefs.last), fixture.betaId);
      expect(
        fixture.registry.entryForRuntimeBinding(
          physicalRef: fixture.alphaRefs.first,
          sourceChatRowId: fixture.betaRows.first,
        ),
        isNull,
      );
    });

    test('cross-conversation split or merge collisions fail closed', () {
      final fixture = _registryFixture();
      final alpha = fixture.registry.entryForLogicalId(fixture.alphaId)!;
      final beta = fixture.registry.entryForLogicalId(fixture.betaId)!;
      final split = LogicalConversationRegistryEntry(
        logicalId: LogicalConversationId.certified('split-attempt'),
        members: <LogicalConversationRegistryMember>[
          _member('split-new', 900, presentation: true),
          LogicalConversationRegistryMember(
            physicalRef: alpha.members.first.physicalRef,
            sourceChatRowId: 901,
            providerGuidFingerprint: _fingerprint('split-shared-provider'),
            isPresentation: false,
          ),
        ],
      );

      expect(
        () => LogicalConversationRegistry(<LogicalConversationRegistryEntry>[alpha, beta, split]),
        throwsA(isA<StateError>()),
      );
      expect(
        () => LogicalConversationRegistry(<LogicalConversationRegistryEntry>[
          alpha,
          LogicalConversationRegistryEntry(logicalId: alpha.logicalId, members: beta.members),
        ]),
        throwsA(isA<StateError>()),
      );
    });

    test('order, restart row allocation, and empty-cache reconstruction preserve identity', () {
      final original = _registryFixture();
      final restarted = _registryFixture(alphaRows: <int>[401, 402], betaRows: <int>[501, 502], reverse: true);

      expect(restarted.registry.stableFingerprint, original.registry.stableFingerprint);
      for (final ref in <PhysicalConversationRef>[...original.alphaRefs, ...original.betaRefs]) {
        expect(restarted.registry.logicalIdForPhysicalRef(ref), original.registry.logicalIdForPhysicalRef(ref));
      }

      final cacheLossRebound = LogicalConversationRegistry(<LogicalConversationRegistryEntry>[
        for (final entry in original.registry.entries)
          LogicalConversationRegistryEntry(
            logicalId: entry.logicalId,
            members: <LogicalConversationRegistryMember>[
              for (final member in entry.members)
                LogicalConversationRegistryMember(
                  physicalRef: PhysicalConversationRef.fromFingerprint(member.providerGuidFingerprint),
                  sourceChatRowId: member.sourceChatRowId! + 1000,
                  providerGuidFingerprint: member.providerGuidFingerprint,
                  isPresentation: member.isPresentation,
                ),
            ],
          ),
      ]);
      expect(cacheLossRebound.stableFingerprint, original.registry.stableFingerprint);

      expect(LogicalConversationRegistry.empty().entryForLogicalId(original.alphaId), isNull);
      expect(_registryFixture().registry.stableFingerprint, original.registry.stableFingerprint);
    });

    test('same-title or same-participant candidates cannot enroll without a certificate', () {
      final fixture = _registryFixture();
      final unrelated = PhysicalConversationRef.fromStablePhysicalGuid('same-title-and-participants-unrelated');
      const items = <_ChatFixture>[
        _ChatFixture(11, 'same title'),
        _ChatFixture(12, 'same title'),
        _ChatFixture(21, 'same title'),
        _ChatFixture(22, 'same title'),
        _ChatFixture(999, 'same title'),
      ];

      expect(fixture.registry.entryForPhysicalRef(unrelated), isNull);
      expect(fixture.registry.projectConversationList(items, (item) => item.rowId).map((item) => item.rowId), <int>[
        12,
        22,
        999,
      ]);
    });

    test('certificate adapter binds two entries and rejects ambiguous physical reuse', () {
      final alpha = _certificate('alpha-human', <int, String>{11: 'alpha-1', 12: 'alpha-2'}, 12);
      final beta = _certificate('beta-human', <int, String>{21: 'beta-1', 22: 'beta-2'}, 22);
      final bindings = <LogicalConversationPhysicalChatBinding>[
        for (final entry in <int, String>{11: 'alpha-1', 12: 'alpha-2', 21: 'beta-1', 22: 'beta-2'}.entries)
          LogicalConversationPhysicalChatBinding.fromProviderGuid(
            sourceChatRowId: entry.key,
            sourceChatGuid: entry.value,
          ),
      ];

      final registry = LogicalConversationRegistryBinding.bind(
        certificates: <LogicalConversationReadCertificate>[beta, alpha],
        physicalChats: bindings.reversed,
      );
      expect(registry.entries, hasLength(2));
      expect(
        registry.logicalIdForPhysicalRef(PhysicalConversationRef.fromStablePhysicalGuid('alpha-1')),
        LogicalConversationId.certified('alpha-human'),
      );

      final collidingBeta = _certificate('beta-human', <int, String>{21: 'alpha-1', 22: 'beta-2'}, 22);
      expect(
        () => LogicalConversationRegistryBinding.bind(
          certificates: <LogicalConversationReadCertificate>[alpha, collidingBeta],
          physicalChats: <LogicalConversationPhysicalChatBinding>[
            ...bindings,
            LogicalConversationPhysicalChatBinding.fromProviderGuid(sourceChatRowId: 21, sourceChatGuid: 'alpha-1'),
          ],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('missing repository member retains one logical identity and fails closed for that binding', () {
      final certificate = _certificate('alpha-human', <int, String>{11: 'alpha-1', 12: 'alpha-2'}, 12);
      final presentBinding = LogicalConversationPhysicalChatBinding.fromProviderGuid(
        sourceChatRowId: 11,
        sourceChatGuid: 'alpha-1',
      );
      final registry = LogicalConversationRegistryBinding.bind(
        certificates: <LogicalConversationReadCertificate>[certificate],
        physicalChats: <LogicalConversationPhysicalChatBinding>[presentBinding],
      );
      final id = LogicalConversationId.certified('alpha-human');
      final entry = registry.entryForLogicalId(id)!;

      expect(entry.members, hasLength(2));
      expect(
        registry
            .entryForRuntimeBinding(
              physicalRef: PhysicalConversationRef.fromStablePhysicalGuid('alpha-1'),
              sourceChatRowId: 11,
            )
            ?.logicalId,
        id,
      );
      expect(
        registry.entryForRuntimeBinding(
          physicalRef: PhysicalConversationRef.fromStablePhysicalGuid('alpha-2'),
          sourceChatRowId: 12,
        ),
        isNull,
      );
      final fullyBound = LogicalConversationRegistryBinding.bind(
        certificates: <LogicalConversationReadCertificate>[certificate],
        physicalChats: <LogicalConversationPhysicalChatBinding>[
          presentBinding,
          LogicalConversationPhysicalChatBinding.fromProviderGuid(sourceChatRowId: 12, sourceChatGuid: 'alpha-2'),
        ],
      ).entryForLogicalId(id)!;
      expect(entry.runtimePhysicalRefs, hasLength(1));
      expect(fullyBound.runtimePhysicalRefs, hasLength(2));
      expect(entry.certifiedMemberRefs, fullyBound.certifiedMemberRefs);
      expect(
        entry.certifiedRefForRuntimeBinding(
          physicalRef: PhysicalConversationRef.fromStablePhysicalGuid('alpha-1'),
          sourceChatRowId: 11,
        ),
        entry.memberForSourceRowId(11)!.certifiedRef,
      );
      expect(
        fullyBound.certifiedRefForRuntimeBinding(
          physicalRef: PhysicalConversationRef.fromStablePhysicalGuid('alpha-2'),
          sourceChatRowId: 12,
        ),
        entry.presentationMember.certifiedRef,
      );
      expect(
        entry.certifiedRefForRuntimeBinding(
          physicalRef: PhysicalConversationRef.fromStablePhysicalGuid('alpha-2'),
          sourceChatRowId: 12,
        ),
        isNull,
      );
      expect(entry.presentationMember.certifiedRef, fullyBound.presentationMember.certifiedRef);
      expect(
        registry.entryForPhysicalRef(
          PhysicalConversationRef.fromFingerprint(entry.presentationMember.providerGuidFingerprint),
        ),
        isNull,
      );
      final canonicalUnread = LogicalUnreadLedger(certifiedSources: entry.certifiedMemberRefs)
        ..observe(
          LogicalUnreadObservation(source: entry.memberForSourceRowId(11)!.certifiedRef, revision: 1, hasUnread: true),
        );
      final restoredUnread = LogicalUnreadLedger.fromJson(canonicalUnread.toJson());
      expect(restoredUnread.certifiedSources.toSet(), fullyBound.certifiedMemberRefs);
      expect(restoredUnread.hasUnread, isTrue);
      expect(
        registry.projectConversationList(const <_ChatFixture>[_ChatFixture(11, 'alpha')], (item) => item.rowId),
        hasLength(1),
      );
    });
    test('registry entry is the canonical snapshot projection boundary', () {
      final fixture = _registryFixture();
      final entry = fixture.registry.entryForLogicalId(fixture.alphaId)!;
      final ledger = LogicalUnreadLedger(certifiedSources: entry.certifiedMemberRefs);
      for (final ref in entry.certifiedMemberRefs) {
        ledger.observe(LogicalUnreadObservation(source: ref, revision: 1, hasUnread: false));
      }

      final snapshot = entry.snapshot(
        health: LogicalConversationHealth.healthy,
        unreadLedger: ledger,
        searchResults: const <LogicalSearchResult>[],
        mediaItems: const <LogicalMediaItem>[],
        revision: 7,
      );

      expect(snapshot.logicalId, fixture.alphaId);
      expect(snapshot.members, containsAll(entry.certifiedMemberRefs));
      expect(snapshot.revision, 7);
    });
  });
}

({
  LogicalConversationRegistry registry,
  LogicalConversationId alphaId,
  LogicalConversationId betaId,
  List<PhysicalConversationRef> alphaRefs,
  List<PhysicalConversationRef> betaRefs,
  List<int> alphaRows,
  List<int> betaRows,
})
_registryFixture({
  List<int> alphaRows = const <int>[11, 12],
  List<int> betaRows = const <int>[21, 22],
  bool reverse = false,
}) {
  final alphaId = LogicalConversationId.certified('alpha-human');
  final betaId = LogicalConversationId.certified('beta-human');
  final alphaMembers = <LogicalConversationRegistryMember>[
    _member('alpha-1', alphaRows[0]),
    _member('alpha-2', alphaRows[1], presentation: true),
  ];
  final betaMembers = <LogicalConversationRegistryMember>[
    _member('beta-1', betaRows[0]),
    _member('beta-2', betaRows[1], presentation: true),
  ];
  final entries = <LogicalConversationRegistryEntry>[
    LogicalConversationRegistryEntry(logicalId: alphaId, members: reverse ? alphaMembers.reversed : alphaMembers),
    LogicalConversationRegistryEntry(logicalId: betaId, members: reverse ? betaMembers.reversed : betaMembers),
  ];
  final registry = LogicalConversationRegistry(reverse ? entries.reversed : entries);
  return (
    registry: registry,
    alphaId: alphaId,
    betaId: betaId,
    alphaRefs: alphaMembers.map((member) => member.physicalRef).toList(growable: false),
    betaRefs: betaMembers.map((member) => member.physicalRef).toList(growable: false),
    alphaRows: alphaRows,
    betaRows: betaRows,
  );
}

LogicalConversationRegistryMember _member(String seed, int rowId, {bool presentation = false}) {
  return LogicalConversationRegistryMember(
    physicalRef: PhysicalConversationRef.fromStablePhysicalGuid(seed),
    sourceChatRowId: rowId,
    providerGuidFingerprint: _fingerprint(seed),
    isPresentation: presentation,
  );
}

LogicalConversationReadCertificate _certificate(String id, Map<int, String> sources, int presentationRow) {
  final rows = sources.keys.toSet();
  return LogicalConversationReadCertificate(
    schema: logicalConversationReadCertificateSchema,
    id: id,
    members: <LogicalConversationMemberProof>[
      for (final entry in sources.entries)
        LogicalConversationMemberProof(
          sourceChatRowId: entry.key,
          sourceChatGuidHmacSha256: '',
          sourceChatGuidSha256: LogicalConversationRegistryBinding.providerGuidFingerprint(entry.value),
          admissionReceiptCommit: '',
          admissionEvidenceSha256: List<String>.filled(64, 'a').join(),
          evidence: const <LogicalConversationMemberEvidenceKind>{
            LogicalConversationMemberEvidenceKind.stableProviderBackedAppleIdentity,
            LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
            LogicalConversationMemberEvidenceKind.completePairwiseDifferential,
            LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
            LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
          },
          pairwiseComparedSourceRowIds: rows.difference(<int>{entry.key}),
          directRelationshipPeerRowIds: <int>{rows.firstWhere((row) => row != entry.key)},
          minimumStructuredRelationshipCount: 1,
          explanation: 'Independent synthetic certificate evidence.',
        ),
    ],
    presentationSourceChatRowId: presentationRow,
  );
}

String _fingerprint(String seed) => LogicalConversationRegistryBinding.providerGuidFingerprint(seed);

class _ChatFixture {
  const _ChatFixture(this.rowId, this.title);

  final int rowId;
  final String title;
}
