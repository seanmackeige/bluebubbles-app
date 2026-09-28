import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(LogicalConversationViewPolicy.resetRuntimeCertificateForTesting);

  group('N-member read certificate admission', () {
    test('all three physical members retain independent admission proof', () {
      const certificate = LogicalConversationViewPolicy.comcastNodeUpdates;
      expect(certificate.schema, logicalConversationReadCertificateSchema);
      expect(certificate.isValid, isTrue);
      expect(certificate.sourceChatRowIds, {2027, 2155, 2156});

      for (final rowId in [2027, 2155, 2156]) {
        final proof = LogicalConversationViewPolicy.membershipProofFor(rowId);
        expect(proof, isNotNull, reason: 'missing proof for $rowId');
        expect(proof!.hasIndependentAdmissionProof, isTrue, reason: 'incomplete proof for $rowId');
        expect(
          proof.pairwiseComparedSourceRowIds,
          certificate.sourceChatRowIds.difference({rowId}),
          reason: 'pairwise differential missing for $rowId',
        );
      }
    });

    test('input order cannot alter membership', () {
      final orders = [
        [2027, 2155, 2156],
        [2156, 2027, 2155],
        [2155, 2156, 2027],
        [9000, 2156, 2027, 2155],
      ];
      for (final rows in orders) {
        expect(LogicalConversationViewPolicy.resolve(rows), same(LogicalConversationViewPolicy.comcastNodeUpdates));
      }
    });

    test('missing or duplicate certified bindings fail closed', () {
      expect(LogicalConversationViewPolicy.resolve([2155, 2156]), isNull);
      expect(LogicalConversationViewPolicy.resolve([2027, 2155, 2155, 2156]), isNull);
      expect(LogicalConversationViewPolicy.resolve([2027, 2155, 2156, 2156]), isNull);
    });

    test('removing any proof removes only that member', () {
      for (final removed in [2027, 2155, 2156]) {
        final reduced = LogicalConversationViewPolicy.comcastNodeUpdates.withoutMemberProof(removed);
        expect(reduced.isValid, isTrue, reason: 'invalid after removing $removed');
        expect(reduced.sourceChatRowIds, {2027, 2155, 2156}.difference({removed}));
        expect(reduced.proofFor(removed), isNull);
        for (final retained in reduced.sourceChatRowIds) {
          expect(reduced.proofFor(retained), same(LogicalConversationViewPolicy.comcastNodeUpdates.proofFor(retained)));
        }
      }
    });

    test('removing 2027 preserves accepted pair behavior', () {
      final pairCertificate = LogicalConversationViewPolicy.comcastNodeUpdates.withoutMemberProof(2027);
      expect(pairCertificate.isValid, isTrue);
      expect(pairCertificate.sourceChatRowIds, {2155, 2156});
      expect(pairCertificate.proofFor(2027), isNull);
      expect(LogicalConversationViewPolicy.resolveCertificate(pairCertificate, [2155, 2156]), same(pairCertificate));

      final chats = [const _ChatFixture(2155), const _ChatFixture(2156), const _ChatFixture(9000)];
      final projected = LogicalConversationViewPolicy.projectConversationListForCertificate(
        pairCertificate,
        chats,
        (chat) => chat.rowId,
      );
      expect(projected.map((chat) => chat.rowId), [2156, 9000]);
    });

    test('transitive-only candidate proof cannot extend the certificate', () {
      final pairCertificate = LogicalConversationViewPolicy.comcastNodeUpdates.withoutMemberProof(2027);
      const transitiveOnly = LogicalConversationMemberProof(
        sourceChatRowId: 9000,
        sourceChatGuidHmacSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        admissionReceiptCommit: '3432adfd6c7daa67d8d7521207a8d433b3339763',
        evidence: {
          LogicalConversationMemberEvidenceKind.appleBlueBubblesGuidParity,
          LogicalConversationMemberEvidenceKind.exactNormalizedExternalParticipants,
          LogicalConversationMemberEvidenceKind.structuredCrossChatRelationship,
          LogicalConversationMemberEvidenceKind.passiveNaturalProduction,
        },
        pairwiseComparedSourceRowIds: {2156},
        directRelationshipPeerRowIds: {2156},
        minimumStructuredRelationshipCount: 1,
        explanation: 'Only a B-to-C edge is available; A-to-C differential is absent.',
      );
      final invalidExtension = LogicalConversationReadCertificate(
        schema: pairCertificate.schema,
        id: pairCertificate.id,
        members: [...pairCertificate.members, transitiveOnly],
        presentationSourceChatRowId: pairCertificate.presentationSourceChatRowId,
      );
      expect(invalidExtension.isValid, isFalse);
      expect(LogicalConversationViewPolicy.resolveCertificate(invalidExtension, [2155, 2156, 9000]), isNull);
    });

    test('new physical identity advances through evidence without hard-coded ROWID logic', () {
      const candidate = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9107,
        sourceChatGuidSha256: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        admissionEvidenceSha256: '5555555555555555555555555555555555555555555555555555555555555555',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: {2027, 2155, 2156},
        directRelationshipPeerRowIds: {2156},
        structuredRelationshipCount: 2,
        passiveNaturalProduction: true,
        groupIdentityContinuity: true,
        historicalLineage: true,
        explanation: 'Direct structured lineage and complete individual proof for a newly observed identity.',
      );
      final result = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.comcastNodeUpdates,
        const [candidate],
      );
      expect(result.certificate.isValid, isTrue);
      expect(result.certificate.sourceChatRowIds, {2027, 2155, 2156, 9107});
      expect(
        result.decisions.single.classification,
        LogicalConversationCandidateClassification.certifiedCurrentOrHistoricalReadMember,
      );
      for (final member in result.certificate.members) {
        expect(
          member.pairwiseComparedSourceRowIds,
          containsAll(result.certificate.sourceChatRowIds.difference({member.sourceChatRowId})),
        );
      }
    });

    test('reconciled certificate atomically activates projection and mutation guards', () {
      const candidate = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9120,
        sourceChatGuidSha256: 'abababababababababababababababababababababababababababababababab',
        admissionEvidenceSha256: 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: {2027, 2155, 2156},
        directRelationshipPeerRowIds: {2156},
        structuredRelationshipCount: 1,
        passiveNaturalProduction: true,
        groupIdentityContinuity: true,
        historicalLineage: true,
        explanation: 'Runtime activation fixture.',
      );
      final before = LogicalConversationViewPolicy.activeCertificate.revision;
      final reconciliation = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.activeCertificate,
        const [candidate],
      );
      expect(
        LogicalConversationViewPolicy.activateReconciledCertificate(reconciliation, expectedRevision: before),
        isTrue,
      );
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(9120), isTrue);
      expect(LogicalConversationViewPolicy.membershipProofFor(9120), isNotNull);
      final projected = LogicalConversationViewPolicy.projectConversationList(const [
        _ChatFixture(2027),
        _ChatFixture(2155),
        _ChatFixture(2156),
        _ChatFixture(9120),
      ], (chat) => chat.rowId);
      expect(projected.map((chat) => chat.rowId), [2156]);
      expect(
        LogicalConversationViewPolicy.activateReconciledCertificate(reconciliation, expectedRevision: before),
        isFalse,
        reason: 'stale authority revision must not reactivate',
      );
    });

    test('durable runtime certificate survives restart and retains exact GUID custody', () {
      final sourceGuidSha256 = sha256.convert(utf8.encode('logical-provider-guid-v1\u0000future-guid')).toString();
      final candidate = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9121,
        sourceChatGuidSha256: sourceGuidSha256,
        admissionEvidenceSha256: 'dededededededededededededededededededededededededededededededede',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: const {2027, 2155, 2156},
        directRelationshipPeerRowIds: const {2156},
        structuredRelationshipCount: 1,
        passiveNaturalProduction: true,
        groupIdentityContinuity: true,
        historicalLineage: true,
        explanation: 'Durable runtime certificate fixture.',
      );
      final before = LogicalConversationViewPolicy.activeCertificate.revision;
      final reconciliation = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.activeCertificate,
        [candidate],
      );
      expect(
        LogicalConversationViewPolicy.activateReconciledCertificate(reconciliation, expectedRevision: before),
        isTrue,
      );
      final advancedRevision = LogicalConversationViewPolicy.activeCertificate.revision;
      expect(
        LogicalConversationViewPolicy.matchesTransportCertificateBinding(
          expectedCertificateRevision: before,
          sourceChatRowId: 9121,
          sourceChatGuid: 'future-guid',
        ),
        isFalse,
        reason: 'predecessor-certificate receipt must not cross an advancement boundary',
      );
      expect(
        LogicalConversationViewPolicy.matchesTransportCertificateBinding(
          expectedCertificateRevision: advancedRevision,
          sourceChatRowId: 9121,
          sourceChatGuid: 'future-guid',
        ),
        isTrue,
      );
      final persisted = LogicalConversationViewPolicy.encodeRuntimeCertificate(
        LogicalConversationViewPolicy.activeCertificate,
      );

      LogicalConversationViewPolicy.resetRuntimeCertificateForTesting();
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(9121), isFalse);
      expect(LogicalConversationViewPolicy.hydrateRuntimeCertificate(persisted), isTrue);
      expect(LogicalConversationViewPolicy.runtimeCertificateAvailable, isTrue);
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(9121), isTrue);
      expect(LogicalConversationViewPolicy.sourceGuidMatchesActiveProof(9121, 'future-guid'), isTrue);
      expect(LogicalConversationViewPolicy.sourceGuidMatchesActiveProof(9121, 'wrong-guid'), isFalse);
    });

    test('corrupt or regressed runtime certificate fails closed to the banked root', () {
      expect(LogicalConversationViewPolicy.hydrateRuntimeCertificate('{not-json'), isFalse);
      expect(LogicalConversationViewPolicy.runtimeCertificateAvailable, isFalse);
      expect(LogicalConversationViewPolicy.activeCertificate.sourceChatRowIds, {2027, 2155, 2156});

      final decoded =
          jsonDecode(
                LogicalConversationViewPolicy.encodeRuntimeCertificate(
                  LogicalConversationViewPolicy.comcastNodeUpdates,
                ),
              )
              as Map<String, dynamic>;
      final payload = (decoded['certificate'] as Map).cast<String, dynamic>();
      final members = payload['members'] as List;
      (members.first as Map)['sourceChatGuidHmacSha256'] = List.filled(64, '0').join();
      expect(LogicalConversationViewPolicy.hydrateRuntimeCertificate(jsonEncode(decoded)), isFalse);
      expect(LogicalConversationViewPolicy.runtimeCertificateAvailable, isFalse);
      expect(LogicalConversationViewPolicy.activeCertificate.sourceChatRowIds, {2027, 2155, 2156});
    });

    test('candidate ordering cannot change evidence-driven read enrollment', () {
      const first = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9108,
        sourceChatGuidSha256: 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        admissionEvidenceSha256: '6666666666666666666666666666666666666666666666666666666666666666',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: {2027, 2155, 2156, 9109},
        directRelationshipPeerRowIds: {2155},
        structuredRelationshipCount: 1,
        passiveNaturalProduction: true,
        groupIdentityContinuity: false,
        historicalLineage: true,
        explanation: 'First independently proven candidate.',
      );
      const second = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9109,
        sourceChatGuidSha256: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        admissionEvidenceSha256: '7777777777777777777777777777777777777777777777777777777777777777',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: {2027, 2155, 2156, 9108},
        directRelationshipPeerRowIds: {2027},
        structuredRelationshipCount: 1,
        passiveNaturalProduction: true,
        groupIdentityContinuity: true,
        historicalLineage: true,
        explanation: 'Second independently proven candidate.',
      );
      final forward = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.comcastNodeUpdates,
        const [first, second],
      );
      final reverse = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.comcastNodeUpdates,
        const [second, first],
      );
      expect(forward.certificate.revision, reverse.certificate.revision);
      expect(forward.certificate.sourceChatRowIds, reverse.certificate.sourceChatRowIds);
    });

    test('new unproven candidate remains ambiguous and cannot enter the read certificate', () {
      const candidate = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9110,
        sourceChatGuidSha256: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        admissionEvidenceSha256: '8888888888888888888888888888888888888888888888888888888888888888',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: {2156},
        directRelationshipPeerRowIds: {2156},
        structuredRelationshipCount: 1,
        passiveNaturalProduction: true,
        groupIdentityContinuity: true,
        historicalLineage: true,
        explanation: 'Incomplete pairwise proof must fail closed.',
      );
      final result = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.comcastNodeUpdates,
        const [candidate],
      );
      expect(result.certificate, same(LogicalConversationViewPolicy.comcastNodeUpdates));
      expect(result.decisions.single.classification, LogicalConversationCandidateClassification.ambiguousNotEnrolled);
    });

    test('duplicate candidate evidence aborts reconciliation atomically', () {
      const candidate = LogicalConversationCandidateEvidence(
        sourceChatRowId: 9111,
        sourceChatGuidSha256: 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        admissionEvidenceSha256: '9999999999999999999999999999999999999999999999999999999999999999',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: true,
        pairwiseComparedSourceRowIds: {2027, 2155, 2156},
        directRelationshipPeerRowIds: {2156},
        structuredRelationshipCount: 1,
        passiveNaturalProduction: true,
        groupIdentityContinuity: true,
        historicalLineage: true,
        explanation: 'A duplicated universe must not partially advance.',
      );
      final result = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.comcastNodeUpdates,
        const [candidate, candidate],
      );
      expect(result.certificate, same(LogicalConversationViewPolicy.comcastNodeUpdates));
      expect(result.decisions, hasLength(2));
      expect(result.decisions.map((decision) => decision.reason), everyElement('DUPLICATE_CANDIDATE_EVIDENCE'));
    });

    test('participant-set mismatch classifies historical lineage without enrollment', () {
      const candidate = LogicalConversationCandidateEvidence(
        sourceChatRowId: 1674,
        sourceChatGuidSha256: 'e0c906040606a28f6bd9c95abc257d31917977ff4962a451e04169cbe47859f4',
        admissionEvidenceSha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        providerBackedAppleIdentity: true,
        stableCompleteSnapshots: true,
        exactNormalizedExternalParticipants: false,
        pairwiseComparedSourceRowIds: {2027, 2155, 2156},
        directRelationshipPeerRowIds: {},
        structuredRelationshipCount: 0,
        passiveNaturalProduction: true,
        groupIdentityContinuity: false,
        historicalLineage: true,
        explanation: 'Historical prior-participant-set identity.',
      );
      final result = LogicalConversationViewPolicy.reconcileCertificate(
        LogicalConversationViewPolicy.comcastNodeUpdates,
        const [candidate],
      );
      expect(result.certificate.sourceChatRowIds, {2027, 2155, 2156});
      expect(
        result.decisions.single.classification,
        LogicalConversationCandidateClassification.historicalRelatedButNotSameParticipantSet,
      );
    });

    test('fourth candidate is independently historical and not enrolled', () {
      final fourth = LogicalConversationViewPolicy.excludedCandidateProofFor(1674);
      expect(fourth, isNotNull);
      expect(
        fourth!.classification,
        LogicalConversationCandidateClassification.historicalRelatedButNotSameParticipantSet,
      );
      expect(LogicalConversationViewPolicy.isApprovedSourceRowId(1674), isFalse);
      expect(LogicalConversationViewPolicy.membershipProofFor(1674), isNull);
    });

    test('three certified physical chats render as one and ordinary chats remain unchanged', () {
      final chats = [
        const _ChatFixture(2027),
        const _ChatFixture(2155),
        const _ChatFixture(2156),
        const _ChatFixture(1674),
        const _ChatFixture(9000),
      ];
      final projected = LogicalConversationViewPolicy.projectConversationList(chats, (chat) => chat.rowId);
      expect(projected.map((chat) => chat.rowId), [2156, 1674, 9000]);
    });

    test('notification and deep-link sources route to the presentation member', () {
      for (final source in [2027, 2155, 2156]) {
        expect(LogicalConversationViewPolicy.presentationSourceRowIdFor(source, [2155, 2027, 2156]), 2156);
      }
      expect(LogicalConversationViewPolicy.presentationSourceRowIdFor(1674, [2155, 2027, 2156]), 1674);
    });

    test('persisted provenance reconstructs the N-member projection after restart', () {
      final persistedSourceRows = [2027, 2155, 2156, 1674, 9000];
      expect(LogicalConversationViewPolicy.resolve(persistedSourceRows), isNotNull);
      final reloadedSourceRows = List<int>.from(persistedSourceRows.reversed);
      expect(LogicalConversationViewPolicy.resolve(reloadedSourceRows), isNotNull);
    });
  });

  group('unified chronology', () {
    test('orders and paginates across all three physical sources', () {
      final events = [
        _event('a', 2027, 1),
        _event('b', 2155, 5),
        _event('c', 2156, 4),
        _event('d', 2027, 3),
        _event('e', 2155, 2),
      ];
      expect(LogicalConversationViewPolicy.mergePage(events, offset: 1, limit: 3).map((event) => event.guid), [
        'c',
        'd',
        'e',
      ]);
    });

    test('suppresses exact-GUID duplicates but retains equal-content distinct GUIDs', () {
      final same = _event('same-guid', 2027, 3, contentFingerprint: 'same-content');
      final events = [
        same,
        same,
        _event('distinct-a', 2027, 2, contentFingerprint: 'same-content'),
        _event('distinct-b', 2156, 1, contentFingerprint: 'same-content'),
      ];
      final merged = LogicalConversationViewPolicy.mergePage(events);
      expect(merged.where((event) => event.guid == 'same-guid'), hasLength(1));
      expect(merged.where((event) => event.value.contentFingerprint == 'same-content'), hasLength(3));
    });

    test('conflicting provenance for one GUID fails closed', () {
      final events = [_event('ambiguous', 2027, 1), _event('ambiguous', 2156, 1)];
      expect(() => LogicalConversationViewPolicy.mergePage(events), throwsStateError);
    });

    test('preserves physical and message provenance plus all message-local state', () {
      final fixture = _MessageFixture(
        sourceChatGuid: 'synthetic-source-guid',
        sourceChatRowId: 2027,
        sourceMessageRowId: 42,
        senderFingerprint: 'sender-fingerprint',
        attachmentGuids: const ['synthetic-attachment-guid'],
        replyToGuid: 'synthetic-parent-guid',
        deliveryState: 'delivered',
        readState: 'read',
        dateRead: DateTime.utc(2026, 9, 18, 15, 35),
        groupMetadataFingerprint: 'group-metadata-fingerprint',
        contentFingerprint: 'redacted-content-fingerprint',
      );
      final result = LogicalConversationViewPolicy.mergePage([
        LogicalConversationEvent(
          guid: 'synthetic-message-guid',
          sourceChatRowId: fixture.sourceChatRowId,
          timestamp: DateTime.utc(2026, 9, 18, 15, 33),
          provenanceFingerprint: fixture.provenanceFingerprint,
          value: fixture,
        ),
      ]).single.value;
      expect(result.sourceChatGuid, fixture.sourceChatGuid);
      expect(result.sourceChatRowId, fixture.sourceChatRowId);
      expect(result.sourceMessageRowId, fixture.sourceMessageRowId);
      expect(result.senderFingerprint, fixture.senderFingerprint);
      expect(result.attachmentGuids, fixture.attachmentGuids);
      expect(result.replyToGuid, fixture.replyToGuid);
      expect(result.deliveryState, fixture.deliveryState);
      expect(result.readState, fixture.readState);
      expect(result.dateRead, fixture.dateRead);
      expect(result.groupMetadataFingerprint, fixture.groupMetadataFingerprint);
    });

    test('all 20 currently observed cross-chat reactions retain exact targets', () {
      final targets = <LogicalConversationEvent<_MessageFixture>>[];
      final edges = <LogicalConversationEvent<_MessageFixture>>[];
      for (var index = 0; index < 18; index++) {
        final targetGuid = 'pair-target-$index';
        targets.add(_event(targetGuid, 2155, index * 2 + 1));
        edges.add(
          _event(
            'pair-edge-$index',
            2156,
            index * 2 + 2,
            relationshipTargetGuid: targetGuid,
            relationshipType: 'reaction',
          ),
        );
      }
      for (var index = 0; index < 2; index++) {
        final targetGuid = 'third-target-$index';
        targets.add(_event(targetGuid, 2027, 30 + index * 2));
        edges.add(
          _event(
            'third-edge-$index',
            2156,
            31 + index * 2,
            relationshipTargetGuid: targetGuid,
            relationshipType: 'reaction',
          ),
        );
      }

      final merged = LogicalConversationViewPolicy.mergePage([...targets, ...edges]);
      final byGuid = {for (final event in merged) event.guid: event};
      final relationshipEvents = merged.where((event) => event.value.relationshipTargetGuid != null).toList();
      expect(relationshipEvents, hasLength(20));
      for (final edge in relationshipEvents) {
        final target = byGuid[edge.value.relationshipTargetGuid];
        expect(target, isNotNull);
        expect(target!.sourceChatRowId, isNot(edge.sourceChatRowId));
      }
    });

    test('unread semantics are OR across all physical sources', () {
      expect(LogicalConversationViewPolicy.logicalUnread([false, false, false]), isFalse);
      expect(LogicalConversationViewPolicy.logicalUnread([false, true, false]), isTrue);
      expect(LogicalConversationViewPolicy.logicalUnread([true, true, true]), isTrue);
    });
  });
}

LogicalConversationEvent<_MessageFixture> _event(
  String guid,
  int sourceRow,
  int minute, {
  String contentFingerprint = 'content-fingerprint',
  String? relationshipTargetGuid,
  String? relationshipType,
}) {
  final fixture = _MessageFixture(
    sourceChatGuid: 'source-$sourceRow',
    sourceChatRowId: sourceRow,
    sourceMessageRowId: minute,
    senderFingerprint: 'sender-$sourceRow',
    attachmentGuids: const [],
    replyToGuid: null,
    deliveryState: 'unchanged',
    readState: 'unchanged',
    dateRead: null,
    groupMetadataFingerprint: 'group-$sourceRow',
    contentFingerprint: contentFingerprint,
    relationshipTargetGuid: relationshipTargetGuid,
    relationshipType: relationshipType,
  );
  return LogicalConversationEvent(
    guid: guid,
    sourceChatRowId: sourceRow,
    timestamp: DateTime.utc(2026, 9, 18, 15, minute),
    provenanceFingerprint: fixture.provenanceFingerprint,
    value: fixture,
  );
}

class _ChatFixture {
  const _ChatFixture(this.rowId);

  final int rowId;
}

class _MessageFixture {
  const _MessageFixture({
    required this.sourceChatGuid,
    required this.sourceChatRowId,
    required this.sourceMessageRowId,
    required this.senderFingerprint,
    required this.attachmentGuids,
    required this.replyToGuid,
    required this.deliveryState,
    required this.readState,
    required this.dateRead,
    required this.groupMetadataFingerprint,
    required this.contentFingerprint,
    this.relationshipTargetGuid,
    this.relationshipType,
  });

  final String sourceChatGuid;
  final int sourceChatRowId;
  final int sourceMessageRowId;
  final String senderFingerprint;
  final List<String> attachmentGuids;
  final String? replyToGuid;
  final String deliveryState;
  final String readState;
  final DateTime? dateRead;
  final String groupMetadataFingerprint;
  final String contentFingerprint;
  final String? relationshipTargetGuid;
  final String? relationshipType;

  String get provenanceFingerprint =>
      '$sourceChatGuid:$sourceChatRowId:$sourceMessageRowId:$senderFingerprint:${relationshipTargetGuid ?? '-'}';
}
