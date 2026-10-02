import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProjectionEvent {
  const _ProjectionEvent({
    required this.id,
    required this.source,
    required this.timestamp,
    required this.revision,
    required this.kind,
    this.relationshipTarget,
  });

  final String id;
  final String source;
  final int timestamp;
  final int revision;
  final String kind;
  final String? relationshipTarget;

  String get signature => '$id|$source|$timestamp|$revision|$kind|${relationshipTarget ?? ''}';
}

IncrementalLogicalProjection<_ProjectionEvent> _projection() => IncrementalLogicalProjection<_ProjectionEvent>(
  identityOf: (event) => event.id,
  provenanceOf: (event) => event.source,
  compare: (left, right) => left.timestamp.compareTo(right.timestamp),
  equivalent: (left, right) => left.signature == right.signature,
);

List<String> _signatures(Iterable<_ProjectionEvent> events) =>
    events.map((event) => event.signature).toList(growable: false);

List<LogicalConversationPhysicalChatBinding> _bindings(List<int> rows) {
  final anchor = LogicalConversationViewPolicy.bankedReadTrustAnchor;
  if (rows.length != anchor.members.length) throw ArgumentError('ROW_CARDINALITY_MISMATCH');
  return <LogicalConversationPhysicalChatBinding>[
    for (var index = 0; index < rows.length; index++)
      LogicalConversationPhysicalChatBinding.fromGuidSha256(
        sourceChatRowId: rows[index],
        sourceChatGuidSha256: anchor.members[index].sourceChatGuidSha256,
      ),
  ];
}

LogicalConversationReadCertificate _certificate(List<int> rows) {
  final certificate = LogicalConversationViewPolicy.bankedReadTrustAnchor.bind(_bindings(rows));
  if (certificate == null) throw StateError('SANITIZED_CERTIFICATE_BINDING_FAILED');
  return certificate;
}

LogicalConversationCandidateEvidence _candidate({
  required int row,
  required Set<int> comparedRows,
  required int directPeer,
  bool exactParticipants = true,
  bool complete = true,
}) => LogicalConversationCandidateEvidence(
  sourceChatRowId: row,
  sourceChatGuidSha256: logicalActionIdentity('candidate-source', <Object?>[row]),
  admissionEvidenceSha256: logicalActionIdentity('candidate-evidence', <Object?>[row]),
  providerBackedAppleIdentity: true,
  stableCompleteSnapshots: complete,
  exactNormalizedExternalParticipants: exactParticipants,
  pairwiseComparedSourceRowIds: comparedRows,
  directRelationshipPeerRowIds: <int>{directPeer},
  structuredRelationshipCount: 1,
  passiveNaturalProduction: true,
  groupIdentityContinuity: true,
  historicalLineage: true,
  explanation: 'Sanitized independent candidate evidence.',
);

LogicalSendAdmissionReceipt _receipt() => LogicalSendAdmissionReceipt(
  admissionId: 'admission-sanitized-1',
  actionId: 'action-sanitized-1',
  logicalId: 'logical-sanitized',
  draftContentRevision: 1,
  certificateRevision: 'certificate-sanitized',
  authorityRevision: 'authority-sanitized',
  authorityEpoch: 1,
  targetSourceChatRowId: 701,
  targetSourceChatGuid: 'source-sanitized',
  transportTempGuid: 'temp-sanitized-1',
  payloadFingerprint: logicalActionIdentity('payload', const <Object?>['sanitized']),
  intentFingerprint: logicalActionIdentity('intent', const <Object?>['sanitized']),
  providerContextFingerprint: logicalActionIdentity('provider', const <Object?>['sanitized']),
  transportReadinessRevision: logicalActionIdentity('readiness', const <Object?>['sanitized']),
  transportSendDisposition: 'ready',
  committedAtEpochMilliseconds: 1,
);

void main() {
  group('P0 ordering and canonical projection properties', () {
    test('member and candidate ordering cannot alter admission or rejection', () {
      final base = _certificate(<int>[101, 203, 307]);
      const candidateRows = <int>[401, 509, 601];
      final completeUniverse = <int>{...base.sourceChatRowIds, ...candidateRows};
      final candidates = <LogicalConversationCandidateEvidence>[
        for (final row in candidateRows)
          _candidate(
            row: row,
            comparedRows: completeUniverse.difference(<int>{row}),
            directPeer: base.presentationSourceChatRowId,
          ),
      ];
      final expected = LogicalConversationViewPolicy.reconcileCertificate(base, candidates);
      expect(expected.certificate.sourceChatRowIds, completeUniverse);

      for (var seed = 0; seed < 64; seed++) {
        final shuffled = candidates.toList()..shuffle(Random(seed));
        final result = LogicalConversationViewPolicy.reconcileCertificate(base, shuffled);
        expect(result.certificate.revision, expected.certificate.revision, reason: 'candidate seed $seed');
        expect(
          result.decisions.map((decision) => '${decision.sourceChatRowId}:${decision.reason}'),
          expected.decisions.map((decision) => '${decision.sourceChatRowId}:${decision.reason}'),
          reason: 'candidate decisions seed $seed',
        );
      }

      final rejected = _candidate(
        row: 809,
        comparedRows: completeUniverse,
        directPeer: base.presentationSourceChatRowId,
        exactParticipants: false,
      );
      final rejection = LogicalConversationViewPolicy.reconcileCertificate(base, <LogicalConversationCandidateEvidence>[
        rejected,
      ]);
      expect(rejection.certificate.revision, base.revision);
      expect(
        rejection.decisions.single.classification,
        LogicalConversationCandidateClassification.historicalRelatedButNotSameParticipantSet,
      );
    });

    test('incremental random event order equals a canonical rebuild after every checkpoint', () {
      final random = Random(0x5ea1);
      final incremental = _projection();
      final truth = <String, _ProjectionEvent>{};
      var nextId = 0;

      for (var operation = 0; operation < 4000; operation++) {
        final choice = random.nextInt(100);
        if (truth.isEmpty || choice < 58) {
          final id = 'event-${nextId++}';
          final event = _ProjectionEvent(
            id: id,
            source: 'source-${random.nextInt(24)}',
            timestamp: random.nextInt(1000000),
            revision: 1,
            kind: operation.isEven ? 'message' : 'relationship',
            relationshipTarget: operation.isEven ? null : 'target-${random.nextInt(500)}',
          );
          truth[id] = event;
          incremental.upsert(event);
        } else {
          final id = truth.keys.elementAt(random.nextInt(truth.length));
          final current = truth[id]!;
          if (choice < 78) {
            final updated = _ProjectionEvent(
              id: current.id,
              source: current.source,
              timestamp: random.nextInt(1000000),
              revision: current.revision + 1,
              kind: current.kind,
              relationshipTarget: current.relationshipTarget,
            );
            truth[id] = updated;
            incremental.upsert(updated, eventClass: LogicalProjectionEventClass.delayedEvent);
          } else if (choice < 91) {
            expect(
              incremental.upsert(current, eventClass: LogicalProjectionEventClass.duplicateEvent).kind,
              LogicalProjectionDeltaKind.unchanged,
            );
          } else {
            truth.remove(id);
            incremental.remove(id);
          }
        }

        if (operation % 40 == 0 || operation == 3999) {
          final canonical = _projection()..rebuild(truth.values);
          expect(_signatures(incremental.values), _signatures(canonical.values), reason: 'operation $operation');
        }
      }
    });

    test('timeline merge is order-independent, suppresses exact duplicates, and retains relationships', () {
      final events = <LogicalConversationEvent<_ProjectionEvent>>[
        for (var index = 0; index < 400; index++)
          LogicalConversationEvent<_ProjectionEvent>(
            guid: 'message-$index',
            sourceChatRowId: 100 + index % 8,
            timestamp: DateTime.fromMicrosecondsSinceEpoch(index ~/ 3),
            provenanceFingerprint: 'source-${index % 8}',
            value: _ProjectionEvent(
              id: 'message-$index',
              source: 'source-${index % 8}',
              timestamp: index ~/ 3,
              revision: 1,
              kind: index % 5 == 0 ? 'reaction' : 'message',
              relationshipTarget: index % 5 == 0 ? 'message-${max(0, index - 1)}' : null,
            ),
          ),
      ];
      final expected = LogicalConversationViewPolicy.mergePage<_ProjectionEvent>(
        <LogicalConversationEvent<_ProjectionEvent>>[...events, ...events.take(50)],
      ).map((event) => event.guid).toList(growable: false);
      for (var seed = 0; seed < 32; seed++) {
        final shuffled = <LogicalConversationEvent<_ProjectionEvent>>[...events, ...events.take(50)]
          ..shuffle(Random(seed));
        expect(
          LogicalConversationViewPolicy.mergePage<_ProjectionEvent>(
            shuffled,
          ).map((event) => event.guid).toList(growable: false),
          expected,
          reason: 'timeline seed $seed',
        );
      }
      expect(events.where((event) => event.value.relationshipTarget != null), isNotEmpty);
    });
  });

  group('P0 failure injection and restart behavior', () {
    test('provenance conflicts, rebuild boundaries, and stale observation completion fail closed', () {
      final projection = _projection();
      const first = _ProjectionEvent(id: 'same-guid', source: 'source-a', timestamp: 10, revision: 1, kind: 'message');
      projection.upsert(first);
      expect(
        () => projection.upsert(
          const _ProjectionEvent(id: 'same-guid', source: 'source-b', timestamp: 10, revision: 1, kind: 'message'),
        ),
        throwsA(isA<StateError>()),
      );
      expect(projection.values.single.signature, first.signature);
      expect(
        projection.upsert(first, eventClass: LogicalProjectionEventClass.newlyAdmittedMember).kind,
        LogicalProjectionDeltaKind.fullRebuildRequired,
      );
      expect(
        projection.upsert(first, eventClass: LogicalProjectionEventClass.executionGeneration).kind,
        LogicalProjectionDeltaKind.fullRebuildRequired,
      );

      final epochs = LogicalEvidenceObservationEpochTracker();
      final stale = epochs.begin();
      final current = epochs.begin();
      expect(() => epochs.complete(stale), throwsA(isA<StateError>()));
      epochs.complete(current);
      expect(epochs.isCurrent(current), isTrue);
      epochs.invalidate();
      expect(epochs.isCurrent(current), isFalse);
    });

    test('cache loss rebuilds exactly and reconnect compatibility is bounded', () {
      final events = <_ProjectionEvent>[
        for (var index = 0; index < 1200; index++)
          _ProjectionEvent(
            id: 'event-$index',
            source: 'source-${index % 12}',
            timestamp: index * 7 % 997,
            revision: 1,
            kind: index % 4 == 0 ? 'attachment' : 'message',
          ),
      ];
      final beforeRestart = _projection();
      for (final event in events.reversed) {
        beforeRestart.upsert(event, eventClass: LogicalProjectionEventClass.outOfOrderEvent);
      }
      final afterRestart = _projection()..rebuild(events);
      expect(_signatures(afterRestart.values), _signatures(beforeRestart.values));

      const original = LogicalProjectionCacheIdentity(
        logicalId: 'logical',
        certificateRevision: 'certificate',
        memberBindingDigest: 'members',
        authorityRevision: 'authority-a',
        sourceWatermarks: <String, String>{'source-a': '10'},
        eventWatermark: 10,
      );
      const reconnect = LogicalProjectionCacheIdentity(
        logicalId: 'logical',
        certificateRevision: 'certificate',
        memberBindingDigest: 'members',
        authorityRevision: 'authority-b',
        sourceWatermarks: <String, String>{'source-a': '20'},
        eventWatermark: 20,
      );
      expect(original.isCompatibleWith(reconnect), isTrue);
      expect(
        original.isCompatibleWith(
          const LogicalProjectionCacheIdentity(
            logicalId: 'logical',
            certificateRevision: 'certificate-drift',
            memberBindingDigest: 'members',
            authorityRevision: 'authority-a',
            sourceWatermarks: <String, String>{},
            eventWatermark: 0,
          ),
        ),
        isFalse,
      );
      expect(
        original.isCompatibleWith(
          const LogicalProjectionCacheIdentity(
            logicalId: 'logical',
            certificateRevision: 'certificate',
            memberBindingDigest: 'member-drift',
            authorityRevision: 'authority-a',
            sourceWatermarks: <String, String>{},
            eventWatermark: 0,
          ),
        ),
        isFalse,
      );
    });

    test('restart preserves dispatch reservation and converts uncertainty to no-retry ambiguity', () {
      final receipt = _receipt();
      final ledger = LogicalAdmissionLedger.fromEntries(const <Map<String, dynamic>>[]);
      expect(
        ledger.commitBatch(<LogicalSendAdmissionReceipt>[receipt], <String>['initial:${receipt.actionId}']),
        isTrue,
      );
      expect(
        ledger.transition(receipt.admissionId, LogicalOperationState.admitted, LogicalOperationState.dispatchReserved),
        isTrue,
      );

      final restarted = LogicalAdmissionLedger.fromEntries(ledger.entries);
      expect(
        restarted.transition(
          receipt.admissionId,
          LogicalOperationState.dispatchReserved,
          LogicalOperationState.outcomeUnknown,
        ),
        isTrue,
      );
      expect(restarted.hasAmbiguousOutcomeForLogical(receipt.logicalId), isTrue);
      expect(logicalTransportMayRetry(receipt), isFalse);
      expect(logicalSocketEchoMayComplete(receipt), isFalse);
      expect(
        restarted.commitBatch(<LogicalSendAdmissionReceipt>[receipt], <String>['initial:${receipt.actionId}']),
        isFalse,
      );
    });

    test('duplicate candidate universe aborts atomically and sequential arrival requires fresh pairwise proof', () {
      final base = _certificate(<int>[11, 22, 33]);
      final duplicate = _candidate(
        row: 44,
        comparedRows: base.sourceChatRowIds,
        directPeer: base.presentationSourceChatRowId,
      );
      final duplicateResult = LogicalConversationViewPolicy.reconcileCertificate(
        base,
        <LogicalConversationCandidateEvidence>[duplicate, duplicate],
      );
      expect(duplicateResult.certificate.revision, base.revision);
      expect(duplicateResult.decisions, everyElement(isA<LogicalConversationCandidateDecision>()));
      expect(
        duplicateResult.decisions.map((decision) => decision.reason),
        everyElement('DUPLICATE_CANDIDATE_EVIDENCE'),
      );

      final first = LogicalConversationViewPolicy.reconcileCertificate(base, <LogicalConversationCandidateEvidence>[
        duplicate,
      ]).certificate;
      expect(first.sourceChatRowIds, contains(44));
      final staleSecond = _candidate(
        row: 55,
        comparedRows: base.sourceChatRowIds,
        directPeer: base.presentationSourceChatRowId,
      );
      final rejected = LogicalConversationViewPolicy.reconcileCertificate(first, <LogicalConversationCandidateEvidence>[
        staleSecond,
      ]);
      expect(rejected.certificate.revision, first.revision);
      expect(rejected.decisions.single.reason, 'INDIVIDUAL_READ_MEMBERSHIP_PROOF_INCOMPLETE');
    });
  });

  group('P1 application identity and read-surface invariants', () {
    test('list projection is row-allocation independent and preserves ordinary singleton entries', () {
      final random = Random(0x99);
      for (var iteration = 0; iteration < 100; iteration++) {
        final rows = <int>{};
        while (rows.length < 3) {
          rows.add(1000 + random.nextInt(1000000));
        }
        final allocated = rows.toList(growable: false);
        final certificate = _certificate(allocated);
        final ordinary = 2000001 + iteration;
        final input = <int>[ordinary, ...allocated]..shuffle(random);
        final projected = LogicalConversationViewPolicy.projectConversationListForCertificate<int>(
          certificate,
          input,
          (row) => row,
        );
        expect(projected.where(certificate.containsSourceRowId), <int>[certificate.presentationSourceChatRowId]);
        expect(projected, contains(ordinary));
      }
    });

    test('ordinary singleton identity equals its legacy bridge and never collapses distinct physical sources', () {
      for (var index = 0; index < 500; index++) {
        final source = 'ordinary-source-$index';
        final ordinary = LogicalConversationId.ordinarySingleton(source);
        final legacy = ConversationAddress.legacyPhysicalGuid(source);
        expect(legacy.logicalId, ordinary);
        expect(LogicalConversationId.ordinarySingleton(source), ordinary);
        expect(ordinary, isNot(LogicalConversationId.ordinarySingleton('ordinary-source-${index + 1}')));
      }
    });

    test('unread result is invariant to duplicate and delayed observations', () {
      final sources = <PhysicalConversationRef>[
        for (var index = 0; index < 24; index++) PhysicalConversationRef.fromStablePhysicalGuid('source-$index'),
      ];
      final observations = <LogicalUnreadObservation>[
        for (final source in sources)
          for (var revision = 0; revision <= 20; revision++)
            LogicalUnreadObservation(source: source, revision: revision, hasUnread: revision.isOdd),
      ];
      final expected = LogicalUnreadLedger(certifiedSources: sources);
      for (final observation in observations) {
        expected.observe(observation);
      }

      for (var seed = 0; seed < 24; seed++) {
        final shuffled = <LogicalUnreadObservation>[
          ...observations,
          ...observations.where((item) => item.revision == 20),
        ]..shuffle(Random(seed));
        final actual = LogicalUnreadLedger(certifiedSources: sources);
        for (final observation in shuffled) {
          actual.observe(observation);
        }
        expect(jsonEncode(actual.toJson()), jsonEncode(expected.toJson()), reason: 'unread seed $seed');
      }
    });

    test('notification, search, media, and snapshot identity retain exact source provenance', () {
      final logicalId = LogicalConversationId.certified('sanitized-logical');
      final members = <PhysicalConversationRef>[
        for (var index = 0; index < 8; index++) PhysicalConversationRef.fromStablePhysicalGuid('member-$index'),
      ];
      final unread = LogicalUnreadLedger(certifiedSources: members);
      final searches = <LogicalSearchResult>[
        for (var index = 0; index < 80; index++)
          LogicalSearchResult.fromStableMessageId(
            logicalId: logicalId,
            source: members[index % members.length],
            stableMessageId: 'message-$index',
            occurredAtEpochMicroseconds: index % 13,
          ),
      ];
      final media = <LogicalMediaItem>[
        for (var index = 0; index < 80; index++)
          LogicalMediaItem.fromStableIds(
            logicalId: logicalId,
            source: members[index % members.length],
            stableMessageId: 'message-$index',
            stableMediaId: 'attachment-$index',
            kind: index.isEven ? LogicalMediaKind.photo : LogicalMediaKind.link,
            availability: LogicalMediaAvailability.available,
            occurredAtEpochMicroseconds: index % 17,
          ),
      ];
      final forward = LogicalConversationSnapshot(
        logicalId: logicalId,
        members: members,
        health: LogicalConversationHealth.readOnly,
        unreadLedger: unread,
        searchResults: searches,
        mediaItems: media,
        revision: 7,
      );
      final reversed = LogicalConversationSnapshot(
        logicalId: logicalId,
        members: members.reversed,
        health: LogicalConversationHealth.readOnly,
        unreadLedger: unread,
        searchResults: searches.reversed,
        mediaItems: media.reversed,
        revision: 7,
      );
      expect(reversed.fingerprint, forward.fingerprint);
      expect(LogicalConversationSnapshot.fromJson(forward.toJson()).fingerprint, forward.fingerprint);
      expect(forward.notificationIdentity, LogicalNotificationIdentity.fromLogicalId(logicalId));
      expect(forward.searchResults.every((item) => item.address.hasExactMessageAnchor), isTrue);
      expect(forward.mediaItems.every((item) => item.owningMessageAddress.hasExactMessageAnchor), isTrue);

      final tampered = Map<String, dynamic>.from(forward.toJson());
      tampered['notificationIdentity'] = <String, dynamic>{...forward.notificationIdentity.toJson(), 'androidId': 1};
      expect(() => LogicalConversationSnapshot.fromJson(tampered), throwsFormatException);
    });

    test('draft survives restart, reconnect restores identical epoch, and process restart requires one re-arm', () {
      final tracker = LogicalAuthorityRevisionTracker(seedEpoch: 100);
      final revision = tracker.observe(certificateRevision: 'certificate-a', authorityRevision: 'authority-a');
      final draft =
          LogicalDraft.create(
            logicalId: 'logical-sanitized',
            nowEpochMilliseconds: 1000,
            observedRevision: revision,
          ).mergeUserIntent(
            text: 'sanitized draft',
            subject: '',
            attachments: const <LogicalAttachmentIntent>[
              LogicalAttachmentIntent(
                intentId: 'attachment-intent',
                name: 'attachment.bin',
                size: 10,
                isRestorable: true,
                path: '/sanitized/attachment.bin',
              ),
            ],
            reply: const LogicalReplyIntent(
              messageGuid: 'message-source-guid',
              relationshipTargetGuid: 'relationship-target-guid',
              sourceChatRowId: 701,
              sourceChatGuid: 'physical-source-guid',
              part: 0,
            ),
            effectId: null,
            updatedAtEpochMilliseconds: 1001,
            observedRevision: revision,
          );
      final restored = LogicalDraft.fromJson(jsonDecode(jsonEncode(draft.toJson())) as Map<String, dynamic>);
      expect(restored.actionId, draft.actionId);
      expect(restored.contentFingerprint, draft.contentFingerprint);
      expect(restored.reply!.sourceChatGuid, 'physical-source-guid');

      tracker.invalidate('RECONNECT');
      final reconnected = tracker.observe(certificateRevision: 'certificate-a', authorityRevision: 'authority-a');
      expect(reconnected.epoch, revision.epoch);
      expect(reconnected.matchesDraft(restored), isTrue);

      final restartedTracker = LogicalAuthorityRevisionTracker(seedEpoch: 10000);
      final afterRestart = restartedTracker.observe(
        certificateRevision: 'certificate-a',
        authorityRevision: 'authority-a',
      );
      expect(afterRestart.matchesDraft(restored), isFalse);
      final rearmed = restored.rearm(afterRestart, updatedAtEpochMilliseconds: 2000);
      expect(afterRestart.matchesDraft(rearmed), isTrue);
      expect(rearmed.actionId, restored.actionId);
      expect(rearmed.contentRevision, restored.contentRevision);
    });
  });
}
