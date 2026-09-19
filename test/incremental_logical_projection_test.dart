import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pending reaction reparent removes the stale unloaded-parent association', () {
    final messages = ChatMessages();
    final reaction = Message(guid: 'reaction-1', associatedMessageGuid: 'parent-a');

    messages.retainPendingReaction(reaction);
    messages.removePendingReaction(reaction.guid!);
    reaction.associatedMessageGuid = 'parent-b';
    messages.retainPendingReaction(reaction);

    expect(messages.takePendingReactions('parent-a'), isEmpty);
    expect(messages.takePendingReactions('parent-b'), [reaction]);
  });

  group('incremental logical projection differential equivalence', () {
    test('all 14 event classes converge to a full canonical rebuild', () {
      expect(LogicalProjectionEventClass.values.map((eventClass) => eventClass.name), [
        'normalMessage',
        'historicalMemberMessage',
        'reaction',
        'crossChatReaction',
        'reply',
        'attachment',
        'readState',
        'groupMetadata',
        'newPhysicalCandidate',
        'newlyAdmittedMember',
        'executionGeneration',
        'delayedEvent',
        'duplicateEvent',
        'outOfOrderEvent',
      ]);

      final incremental = _newProjection();
      final sourceTruth = <String, _ProjectionFixture>{};
      final exercised = <LogicalProjectionEventClass>{};
      const rebuildClasses = {
        LogicalProjectionEventClass.newlyAdmittedMember,
        LogicalProjectionEventClass.executionGeneration,
      };

      for (var index = 0; index < LogicalProjectionEventClass.values.length; index++) {
        final eventClass = LogicalProjectionEventClass.values[index];
        final event = _eventForClass(eventClass, index);
        sourceTruth[event.id] = event;
        exercised.add(eventClass);

        final before = _snapshot(incremental.values);
        final delta = incremental.upsert(event, eventClass: eventClass);
        if (rebuildClasses.contains(eventClass)) {
          expect(delta.kind, LogicalProjectionDeltaKind.fullRebuildRequired, reason: eventClass.name);
          expect(delta.reason, eventClass.name);
          expect(_snapshot(incremental.values), before, reason: '${eventClass.name} mutated before fallback');
          incremental.rebuild(sourceTruth.values);
        } else {
          expect(delta.kind, LogicalProjectionDeltaKind.inserted, reason: eventClass.name);
        }

        _expectMatchesFull(incremental, sourceTruth.values, reason: eventClass.name);
      }

      expect(exercised, LogicalProjectionEventClass.values.toSet());
      expect(incremental.values, hasLength(LogicalProjectionEventClass.values.length));
      expect(
        incremental.values.singleWhere((event) => event.eventClass == LogicalProjectionEventClass.reply).replyTarget,
        'normalMessage-0',
      );
      expect(
        incremental.values
            .singleWhere((event) => event.eventClass == LogicalProjectionEventClass.attachment)
            .attachmentReference,
        'attachment-intent-5',
      );
      expect(
        incremental.values.singleWhere((event) => event.eventClass == LogicalProjectionEventClass.readState).readState,
        'read',
      );
      expect(
        incremental.values
            .singleWhere((event) => event.eventClass == LogicalProjectionEventClass.groupMetadata)
            .groupMetadata,
        'group-revision-7',
      );
    });

    test('identical duplicate replay is idempotent', () {
      final incremental = _newProjection();
      final event = _event(
        id: 'duplicate',
        sourceChatRowId: 2156,
        sourceMessageRowId: 1,
        sortKey: 100,
        eventClass: LogicalProjectionEventClass.duplicateEvent,
      );

      final inserted = incremental.upsert(event, eventClass: LogicalProjectionEventClass.duplicateEvent);
      final replayed = incremental.upsert(event, eventClass: LogicalProjectionEventClass.duplicateEvent);

      expect(inserted.kind, LogicalProjectionDeltaKind.inserted);
      expect(replayed.kind, LogicalProjectionDeltaKind.unchanged);
      expect(replayed.oldIndex, 0);
      expect(replayed.newIndex, isNull);
      expect(incremental.values, [event]);

      final full = _newProjection()..rebuild([event, event]);
      expect(_snapshot(incremental.values), _snapshot(full.values));
    });

    test('conflicting provenance fails closed without corrupting the accepted projection', () {
      final incremental = _newProjection();
      final accepted = _event(
        id: 'same-id',
        sourceChatRowId: 2027,
        sourceMessageRowId: 41,
        sortKey: 100,
        eventClass: LogicalProjectionEventClass.historicalMemberMessage,
      );
      final conflict = _event(
        id: 'same-id',
        sourceChatRowId: 2156,
        sourceMessageRowId: 99,
        sortKey: 200,
        eventClass: LogicalProjectionEventClass.normalMessage,
      );
      incremental.upsert(accepted);
      final before = _snapshot(incremental.values);

      expect(
        () => incremental.upsert(conflict),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'bounded conflict',
            contains('LOGICAL_EVENT_PROVENANCE_CONFLICT:same-id'),
          ),
        ),
      );
      expect(_snapshot(incremental.values), before);

      expect(
        () => _newProjection().rebuild([accepted, conflict]),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'bounded conflict',
            contains('LOGICAL_EVENT_PROVENANCE_CONFLICT:same-id'),
          ),
        ),
      );
    });

    test('out-of-order and delayed arrivals converge after every insertion', () {
      final arrivals = [
        _event(
          id: 'late-old',
          sourceChatRowId: 2027,
          sourceMessageRowId: 1,
          sortKey: 100,
          eventClass: LogicalProjectionEventClass.delayedEvent,
        ),
        _event(
          id: 'newest-z',
          sourceChatRowId: 2156,
          sourceMessageRowId: 5,
          sortKey: 500,
          eventClass: LogicalProjectionEventClass.normalMessage,
        ),
        _event(
          id: 'middle-reaction',
          sourceChatRowId: 2155,
          sourceMessageRowId: 3,
          sortKey: 300,
          eventClass: LogicalProjectionEventClass.crossChatReaction,
          relationshipTarget: 'late-old',
        ),
        _event(
          id: 'newest-a',
          sourceChatRowId: 2155,
          sourceMessageRowId: 4,
          sortKey: 500,
          eventClass: LogicalProjectionEventClass.outOfOrderEvent,
        ),
        _event(
          id: 'oldest',
          sourceChatRowId: 2027,
          sourceMessageRowId: 0,
          sortKey: 50,
          eventClass: LogicalProjectionEventClass.historicalMemberMessage,
        ),
      ];
      final incremental = _newProjection();
      final sourceTruth = <_ProjectionFixture>[];

      for (final event in arrivals) {
        sourceTruth.add(event);
        expect(incremental.upsert(event, eventClass: event.eventClass).kind, LogicalProjectionDeltaKind.inserted);
        _expectMatchesFull(incremental, sourceTruth, reason: event.id);
      }

      expect(incremental.values.map((event) => event.id), [
        'newest-a',
        'newest-z',
        'middle-reaction',
        'late-old',
        'oldest',
      ]);
      expect(incremental.values[2].relationshipTarget, 'late-old');
    });

    test('same-provenance update reorders canonically and removal remains differential-equivalent', () {
      final moving = _event(
        id: 'moving',
        sourceChatRowId: 2156,
        sourceMessageRowId: 1,
        sortKey: 100,
        eventClass: LogicalProjectionEventClass.normalMessage,
        payloadRevision: 1,
      );
      final peerNewest = _event(
        id: 'peer-newest',
        sourceChatRowId: 2155,
        sourceMessageRowId: 2,
        sortKey: 300,
        eventClass: LogicalProjectionEventClass.historicalMemberMessage,
      );
      final peerMiddle = _event(
        id: 'peer-middle',
        sourceChatRowId: 2027,
        sourceMessageRowId: 3,
        sortKey: 200,
        eventClass: LogicalProjectionEventClass.historicalMemberMessage,
      );
      final sourceTruth = <String, _ProjectionFixture>{
        moving.id: moving,
        peerNewest.id: peerNewest,
        peerMiddle.id: peerMiddle,
      };
      final incremental = _newProjection()..rebuild(sourceTruth.values);
      expect(incremental.values.map((event) => event.id), ['peer-newest', 'peer-middle', 'moving']);

      final updated = _event(
        id: moving.id,
        sourceChatRowId: moving.sourceChatRowId,
        sourceMessageRowId: moving.sourceMessageRowId,
        sortKey: 400,
        eventClass: moving.eventClass,
        payloadRevision: 2,
        readState: 'delivered',
      );
      sourceTruth[updated.id] = updated;
      final update = incremental.upsert(updated, eventClass: updated.eventClass);

      expect(update.kind, LogicalProjectionDeltaKind.updated);
      expect(update.oldIndex, 2);
      expect(update.newIndex, 0);
      expect(incremental.values.map((event) => event.id), ['moving', 'peer-newest', 'peer-middle']);
      _expectMatchesFull(incremental, sourceTruth.values);

      sourceTruth.remove(peerNewest.id);
      final removed = incremental.remove(peerNewest.id);
      expect(removed.kind, LogicalProjectionDeltaKind.removed);
      expect(removed.oldIndex, 1);
      _expectMatchesFull(incremental, sourceTruth.values);
      expect(incremental.remove('absent').kind, LogicalProjectionDeltaKind.unchanged);
    });
  });

  group('logical projection cache identity and recovery', () {
    test('structural identity invalidates while authority and watermarks remain detectable catch-up metadata', () {
      const base = LogicalProjectionCacheIdentity(
        logicalId: 'logical-comcast-node-updates',
        certificateRevision: 'certificate-r1',
        memberBindingDigest: 'members-2027-2155-2156',
        authorityRevision: 'authority-r1',
        sourceWatermarks: {'2027': '10', '2155': '20', '2156': '30'},
        eventWatermark: 30,
      );
      const advanced = LogicalProjectionCacheIdentity(
        logicalId: 'logical-comcast-node-updates',
        certificateRevision: 'certificate-r1',
        memberBindingDigest: 'members-2027-2155-2156',
        authorityRevision: 'authority-r2',
        sourceWatermarks: {'2027': '11', '2155': '20', '2156': '35'},
        eventWatermark: 35,
      );

      expect(base.isCompatibleWith(advanced), isTrue);
      expect(advanced.isCompatibleWith(base), isTrue);
      expect(base.authorityRevision, isNot(advanced.authorityRevision));
      expect(base.sourceWatermarks, isNot(equals(advanced.sourceWatermarks)));
      expect(base.eventWatermark, isNot(advanced.eventWatermark));

      final incompatible = [
        const LogicalProjectionCacheIdentity(
          logicalId: 'different-logical-conversation',
          certificateRevision: 'certificate-r1',
          memberBindingDigest: 'members-2027-2155-2156',
          authorityRevision: 'authority-r1',
          sourceWatermarks: {'2027': '10'},
          eventWatermark: 10,
        ),
        const LogicalProjectionCacheIdentity(
          logicalId: 'logical-comcast-node-updates',
          certificateRevision: 'certificate-r2',
          memberBindingDigest: 'members-2027-2155-2156',
          authorityRevision: 'authority-r1',
          sourceWatermarks: {'2027': '10'},
          eventWatermark: 10,
        ),
        const LogicalProjectionCacheIdentity(
          logicalId: 'logical-comcast-node-updates',
          certificateRevision: 'certificate-r1',
          memberBindingDigest: 'members-2027-2155-2156-9000',
          authorityRevision: 'authority-r1',
          sourceWatermarks: {'2027': '10'},
          eventWatermark: 10,
        ),
      ];
      for (final identity in incompatible) {
        expect(base.isCompatibleWith(identity), isFalse);
        expect(identity.isCompatibleWith(base), isFalse);
      }
    });

    test('cache loss reconstructs the exact canonical projection from source truth', () {
      final sourceTruth = [
        _event(
          id: 'reply',
          sourceChatRowId: 2156,
          sourceMessageRowId: 4,
          sortKey: 400,
          eventClass: LogicalProjectionEventClass.reply,
          replyTarget: 'historical',
        ),
        _event(
          id: 'historical',
          sourceChatRowId: 2027,
          sourceMessageRowId: 1,
          sortKey: 100,
          eventClass: LogicalProjectionEventClass.historicalMemberMessage,
        ),
        _event(
          id: 'attachment',
          sourceChatRowId: 2155,
          sourceMessageRowId: 3,
          sortKey: 300,
          eventClass: LogicalProjectionEventClass.attachment,
          attachmentReference: 'local-safe-reference',
        ),
      ];
      final live = _newProjection();
      for (final event in sourceTruth) {
        live.upsert(event, eventClass: event.eventClass);
      }
      final beforeLoss = _snapshot(live.values);

      final recovered = _newProjection();
      expect(recovered.values, isEmpty);
      recovered.rebuild(sourceTruth);

      expect(_snapshot(recovered.values), beforeLoss);
      _expectMatchesFull(recovered, sourceTruth);
    });
  });

  group('member cardinality differential equivalence', () {
    test('N-member Comcast history is identical under incremental and full projection', () {
      final arrivals = <_ProjectionFixture>[];
      for (var index = 0; index < 12; index++) {
        final source = const [2027, 2155, 2156][index % 3];
        arrivals.add(
          _event(
            id: 'n-member-$index',
            sourceChatRowId: source,
            sourceMessageRowId: index,
            sortKey: (index * 37) % 101,
            eventClass: index.isEven
                ? LogicalProjectionEventClass.normalMessage
                : LogicalProjectionEventClass.historicalMemberMessage,
          ),
        );
      }

      final incremental = _exerciseAgainstFull(arrivals);
      expect(incremental.values.map((event) => event.sourceChatRowId).toSet(), {2027, 2155, 2156});
      expect(incremental.values, hasLength(arrivals.length));
    });

    test('ordinary one-member history is identical under incremental and full projection', () {
      final arrivals = [
        for (var index = 0; index < 8; index++)
          _event(
            id: 'ordinary-$index',
            sourceChatRowId: 42,
            sourceMessageRowId: index,
            sortKey: (index * 19) % 43,
            eventClass: LogicalProjectionEventClass.normalMessage,
          ),
      ];

      final incremental = _exerciseAgainstFull(arrivals);
      expect(incremental.values.map((event) => event.sourceChatRowId).toSet(), {42});
      expect(incremental.values, hasLength(arrivals.length));
    });
  });
}

IncrementalLogicalProjection<_ProjectionFixture> _newProjection() {
  return IncrementalLogicalProjection<_ProjectionFixture>(
    identityOf: (event) => event.id,
    provenanceOf: (event) => event.provenanceFingerprint,
    compare: (left, right) => right.sortKey.compareTo(left.sortKey),
    equivalent: (left, right) => left == right,
  );
}

IncrementalLogicalProjection<_ProjectionFixture> _exerciseAgainstFull(List<_ProjectionFixture> arrivals) {
  final incremental = _newProjection();
  final sourceTruth = <_ProjectionFixture>[];
  for (final event in arrivals) {
    sourceTruth.add(event);
    final delta = incremental.upsert(event, eventClass: event.eventClass);
    expect(delta.kind, LogicalProjectionDeltaKind.inserted, reason: event.id);
    _expectMatchesFull(incremental, sourceTruth, reason: event.id);
  }
  return incremental;
}

void _expectMatchesFull(
  IncrementalLogicalProjection<_ProjectionFixture> incremental,
  Iterable<_ProjectionFixture> sourceTruth, {
  String? reason,
}) {
  final full = _newProjection()..rebuild(sourceTruth);
  expect(_snapshot(incremental.values), _snapshot(full.values), reason: reason);
}

List<String> _snapshot(Iterable<_ProjectionFixture> events) {
  return [for (final event in events) event.snapshot];
}

_ProjectionFixture _eventForClass(LogicalProjectionEventClass eventClass, int index) {
  final source = const [2027, 2155, 2156][index % 3];
  final base = <String, Object?>{
    'id': '${eventClass.name}-$index',
    'sourceChatRowId': source,
    'sourceMessageRowId': index,
    'sortKey': (index * 17) % 53,
    'eventClass': eventClass,
  };
  switch (eventClass) {
    case LogicalProjectionEventClass.reaction:
    case LogicalProjectionEventClass.crossChatReaction:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: base['sourceChatRowId']! as int,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
        relationshipTarget: 'normalMessage-0',
      );
    case LogicalProjectionEventClass.reply:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: base['sourceChatRowId']! as int,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
        replyTarget: 'normalMessage-0',
      );
    case LogicalProjectionEventClass.attachment:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: base['sourceChatRowId']! as int,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
        attachmentReference: 'attachment-intent-$index',
      );
    case LogicalProjectionEventClass.readState:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: base['sourceChatRowId']! as int,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
        readState: 'read',
      );
    case LogicalProjectionEventClass.groupMetadata:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: base['sourceChatRowId']! as int,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
        groupMetadata: 'group-revision-$index',
      );
    case LogicalProjectionEventClass.newPhysicalCandidate:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: 9000,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
      );
    case LogicalProjectionEventClass.newlyAdmittedMember:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: 9000,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
      );
    case LogicalProjectionEventClass.normalMessage:
    case LogicalProjectionEventClass.historicalMemberMessage:
    case LogicalProjectionEventClass.executionGeneration:
    case LogicalProjectionEventClass.delayedEvent:
    case LogicalProjectionEventClass.duplicateEvent:
    case LogicalProjectionEventClass.outOfOrderEvent:
      return _event(
        id: base['id']! as String,
        sourceChatRowId: base['sourceChatRowId']! as int,
        sourceMessageRowId: base['sourceMessageRowId']! as int,
        sortKey: base['sortKey']! as int,
        eventClass: eventClass,
      );
  }
}

_ProjectionFixture _event({
  required String id,
  required int sourceChatRowId,
  required int sourceMessageRowId,
  required int sortKey,
  required LogicalProjectionEventClass eventClass,
  int payloadRevision = 0,
  String? relationshipTarget,
  String? replyTarget,
  String? attachmentReference,
  String readState = 'unchanged',
  String? groupMetadata,
}) {
  return _ProjectionFixture(
    id: id,
    sourceChatRowId: sourceChatRowId,
    sourceMessageRowId: sourceMessageRowId,
    sortKey: sortKey,
    eventClass: eventClass,
    payloadRevision: payloadRevision,
    relationshipTarget: relationshipTarget,
    replyTarget: replyTarget,
    attachmentReference: attachmentReference,
    readState: readState,
    groupMetadata: groupMetadata,
    provenanceFingerprint:
        '$sourceChatRowId:$sourceMessageRowId:${relationshipTarget ?? '-'}:${replyTarget ?? '-'}:${attachmentReference ?? '-'}',
  );
}

class _ProjectionFixture {
  const _ProjectionFixture({
    required this.id,
    required this.sourceChatRowId,
    required this.sourceMessageRowId,
    required this.sortKey,
    required this.eventClass,
    required this.payloadRevision,
    required this.relationshipTarget,
    required this.replyTarget,
    required this.attachmentReference,
    required this.readState,
    required this.groupMetadata,
    required this.provenanceFingerprint,
  });

  final String id;
  final int sourceChatRowId;
  final int sourceMessageRowId;
  final int sortKey;
  final LogicalProjectionEventClass eventClass;
  final int payloadRevision;
  final String? relationshipTarget;
  final String? replyTarget;
  final String? attachmentReference;
  final String readState;
  final String? groupMetadata;
  final String provenanceFingerprint;

  String get snapshot => [
    id,
    sourceChatRowId,
    sourceMessageRowId,
    sortKey,
    eventClass.name,
    payloadRevision,
    relationshipTarget,
    replyTarget,
    attachmentReference,
    readState,
    groupMetadata,
    provenanceFingerprint,
  ].join('|');

  @override
  bool operator ==(Object other) {
    return other is _ProjectionFixture &&
        id == other.id &&
        sourceChatRowId == other.sourceChatRowId &&
        sourceMessageRowId == other.sourceMessageRowId &&
        sortKey == other.sortKey &&
        eventClass == other.eventClass &&
        payloadRevision == other.payloadRevision &&
        relationshipTarget == other.relationshipTarget &&
        replyTarget == other.replyTarget &&
        attachmentReference == other.attachmentReference &&
        readState == other.readState &&
        groupMetadata == other.groupMetadata &&
        provenanceFingerprint == other.provenanceFingerprint;
  }

  @override
  int get hashCode => Object.hash(
    id,
    sourceChatRowId,
    sourceMessageRowId,
    sortKey,
    eventClass,
    payloadRevision,
    relationshipTarget,
    replyTarget,
    attachmentReference,
    readState,
    groupMetadata,
    provenanceFingerprint,
  );
}
