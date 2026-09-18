import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

    test('fourth candidate is independently historical and not enrolled', () {
      final fourth = LogicalConversationViewPolicy.excludedCandidateProofFor(1674);
      expect(fourth, isNotNull);
      expect(fourth!.classification, LogicalConversationCandidateClassification.historicalInertRelatedIdentity);
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

    test('all 14 currently observed cross-chat reactions retain exact targets', () {
      final targets = <LogicalConversationEvent<_MessageFixture>>[];
      final edges = <LogicalConversationEvent<_MessageFixture>>[];
      for (var index = 0; index < 12; index++) {
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
      expect(relationshipEvents, hasLength(14));
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
