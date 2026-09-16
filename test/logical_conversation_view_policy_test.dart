import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('golden-pair admission', () {
    test('admits only one exact binding for both approved ROWIDs', () {
      final definition = LogicalConversationViewPolicy.resolve([2155, 2156, 9000]);
      expect(definition, same(LogicalConversationViewPolicy.goldenPair));
      expect(definition!.outboundExecutionEnabled, isFalse);
    });

    test('missing or ambiguous mappings fail closed', () {
      expect(LogicalConversationViewPolicy.resolve([2155]), isNull);
      expect(LogicalConversationViewPolicy.resolve([2155, 2155, 2156]), isNull);
      expect(LogicalConversationViewPolicy.resolve([2155, 2156, 2156]), isNull);
    });

    test('unapproved and similar-participant chats remain separate', () {
      final chats = [const _ChatFixture(9000, 'same-participants-a'), const _ChatFixture(9001, 'same-participants-b')];
      expect(LogicalConversationViewPolicy.projectConversationList(chats, (chat) => chat.rowId), chats);
    });

    test('conversation list contains one presentation entry for the golden pair', () {
      final chats = [
        const _ChatFixture(2155, 'source-a'),
        const _ChatFixture(2156, 'source-b'),
        const _ChatFixture(9000, 'unrelated'),
      ];
      final projected = LogicalConversationViewPolicy.projectConversationList(chats, (chat) => chat.rowId);
      expect(projected.map((chat) => chat.rowId), [2156, 9000]);
    });

    test('notification and deep-link source routes to the presentation ROWID', () {
      for (final source in [2155, 2156]) {
        expect(LogicalConversationViewPolicy.presentationSourceRowIdFor(source, [2155, 2156]), 2156);
      }
      expect(LogicalConversationViewPolicy.presentationSourceRowIdFor(9000, [2155, 2156]), 9000);
    });

    test('persisted provenance reconstructs the projection after restart', () {
      final persistedSourceRows = [2155, 2156, 9000];
      expect(LogicalConversationViewPolicy.resolve(persistedSourceRows), isNotNull);
      final reloadedSourceRows = List<int>.from(persistedSourceRows);
      expect(LogicalConversationViewPolicy.resolve(reloadedSourceRows), isNotNull);
    });
  });

  group('unified chronology', () {
    test('orders and paginates across both physical sources', () {
      final events = [_event('a', 2155, 1), _event('b', 2156, 4), _event('c', 2155, 3), _event('d', 2156, 2)];
      expect(LogicalConversationViewPolicy.mergePage(events, offset: 1, limit: 2).map((event) => event.guid), [
        'c',
        'd',
      ]);
    });

    test('suppresses exact-GUID duplicates but retains equal-content distinct GUIDs', () {
      final same = _event('same-guid', 2155, 3, contentFingerprint: 'same-content');
      final events = [
        same,
        same,
        _event('distinct-a', 2155, 2, contentFingerprint: 'same-content'),
        _event('distinct-b', 2156, 1, contentFingerprint: 'same-content'),
      ];
      final merged = LogicalConversationViewPolicy.mergePage(events);
      expect(merged.where((event) => event.guid == 'same-guid'), hasLength(1));
      expect(merged.where((event) => event.value.contentFingerprint == 'same-content'), hasLength(3));
    });

    test('conflicting provenance for one GUID fails closed', () {
      final events = [_event('ambiguous', 2155, 1), _event('ambiguous', 2156, 1)];
      expect(() => LogicalConversationViewPolicy.mergePage(events), throwsStateError);
    });

    test('preserves message provenance, attachment, reply, delivery, and read fields', () {
      final fixture = _MessageFixture(
        sourceChatGuid: 'synthetic-source-guid',
        sourceChatRowId: 2156,
        sourceMessageRowId: 42,
        senderFingerprint: 'sender-fingerprint',
        attachmentGuids: const ['synthetic-attachment-guid'],
        replyToGuid: 'synthetic-parent-guid',
        deliveryState: 'delivered',
        readState: 'read',
        dateRead: DateTime.utc(2026, 9, 16, 15, 35),
        contentFingerprint: 'redacted-content-fingerprint',
      );
      final result = LogicalConversationViewPolicy.mergePage([
        LogicalConversationEvent(
          guid: 'synthetic-message-guid',
          sourceChatRowId: fixture.sourceChatRowId,
          timestamp: DateTime.utc(2026, 9, 16, 15, 33),
          provenanceFingerprint: fixture.provenanceFingerprint,
          value: fixture,
        ),
      ]).single.value;
      expect(result.sourceChatGuid, fixture.sourceChatGuid);
      expect(result.sourceMessageRowId, fixture.sourceMessageRowId);
      expect(result.senderFingerprint, fixture.senderFingerprint);
      expect(result.attachmentGuids, fixture.attachmentGuids);
      expect(result.replyToGuid, fixture.replyToGuid);
      expect(result.deliveryState, fixture.deliveryState);
      expect(result.readState, fixture.readState);
      expect(result.dateRead, fixture.dateRead);
    });

    test('all retained and fresh cross-chat relationship fixtures resolve', () {
      final targets = <LogicalConversationEvent<_MessageFixture>>[];
      final edges = <LogicalConversationEvent<_MessageFixture>>[];
      for (var index = 0; index < 9; index++) {
        final targetRow = index.isEven ? 2155 : 2156;
        final edgeRow = targetRow == 2155 ? 2156 : 2155;
        final targetGuid = 'retained-target-$index';
        targets.add(_event(targetGuid, targetRow, index * 2 + 1));
        edges.add(
          _event(
            'retained-edge-$index',
            edgeRow,
            index * 2 + 2,
            relationshipTargetGuid: targetGuid,
            relationshipType: 'reaction',
          ),
        );
      }

      // Public-safe natural fixture: direction, minute, and relationship only.
      final freshTarget = _event('fresh-target', 2156, 33);
      final freshEdge = _event(
        'fresh-edge',
        2155,
        34,
        relationshipTargetGuid: freshTarget.guid,
        relationshipType: 'like',
      );
      final merged = LogicalConversationViewPolicy.mergePage([...targets, ...edges, freshTarget, freshEdge]);
      final byGuid = {for (final event in merged) event.guid: event};
      final relationshipEvents = merged.where((event) => event.value.relationshipTargetGuid != null).toList();

      expect(relationshipEvents, hasLength(10));
      for (final edge in relationshipEvents) {
        final target = byGuid[edge.value.relationshipTargetGuid];
        expect(target, isNotNull);
        expect(target!.sourceChatRowId, isNot(edge.sourceChatRowId));
      }
    });

    test('unread semantics are OR across sources', () {
      expect(LogicalConversationViewPolicy.logicalUnread([false, false]), isFalse);
      expect(LogicalConversationViewPolicy.logicalUnread([false, true]), isTrue);
      expect(LogicalConversationViewPolicy.logicalUnread([true, true]), isTrue);
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
    contentFingerprint: contentFingerprint,
    relationshipTargetGuid: relationshipTargetGuid,
    relationshipType: relationshipType,
  );
  return LogicalConversationEvent(
    guid: guid,
    sourceChatRowId: sourceRow,
    timestamp: DateTime.utc(2026, 9, 16, 15, minute),
    provenanceFingerprint: fixture.provenanceFingerprint,
    value: fixture,
  );
}

class _ChatFixture {
  const _ChatFixture(this.rowId, this.participantFingerprint);

  final int rowId;
  final String participantFingerprint;
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
  final String contentFingerprint;
  final String? relationshipTargetGuid;
  final String? relationshipType;

  String get provenanceFingerprint =>
      '$sourceChatGuid:$sourceChatRowId:$sourceMessageRowId:$senderFingerprint:${relationshipTargetGuid ?? '-'}';
}
