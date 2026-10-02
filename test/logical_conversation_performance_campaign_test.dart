import 'dart:convert';
import 'dart:math';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter_test/flutter_test.dart';

class _BenchEvent {
  const _BenchEvent({required this.id, required this.source, required this.timestamp, required this.kind});

  final String id;
  final String source;
  final int timestamp;
  final LogicalProjectionEventClass kind;

  String get signature => '$id|$source|$timestamp|${kind.name}';
}

IncrementalLogicalProjection<_BenchEvent> _projection() => IncrementalLogicalProjection<_BenchEvent>(
  identityOf: (event) => event.id,
  provenanceOf: (event) => event.source,
  compare: (left, right) => left.timestamp.compareTo(right.timestamp),
  equivalent: (left, right) => left.signature == right.signature,
);

void main() {
  test('benchmark: canonical rebuild handles long mixed history within 8 seconds', () {
    const eventCount = 50000;
    const duplicateCount = 5000;
    final events = <_BenchEvent>[
      for (var index = 0; index < eventCount; index++)
        _BenchEvent(
          id: 'event-$index',
          source: 'source-${index % 64}',
          timestamp: index * 7919 % 1000003,
          kind: index % 7 == 0
              ? LogicalProjectionEventClass.reaction
              : index % 5 == 0
              ? LogicalProjectionEventClass.attachment
              : LogicalProjectionEventClass.normalMessage,
        ),
    ];
    final input = <_BenchEvent>[...events, ...events.take(duplicateCount)]..shuffle(Random(0x50000));
    final projection = _projection();
    final stopwatch = Stopwatch()..start();
    projection.rebuild(input);
    stopwatch.stop();

    expect(projection.values, hasLength(eventCount));
    expect(projection.values.where((event) => event.kind == LogicalProjectionEventClass.reaction), isNotEmpty);
    expect(projection.values.where((event) => event.kind == LogicalProjectionEventClass.attachment), isNotEmpty);
    // ignore: avoid_print
    print(
      'BENCH canonical_rebuild events=$eventCount duplicates=$duplicateCount ms=${stopwatch.elapsedMilliseconds} threshold_ms=8000',
    );
    expect(stopwatch.elapsedMilliseconds, lessThan(8000));
  });

  test('benchmark: shuffled incremental projection matches canonical at 20000 events within 8 seconds', () {
    const eventCount = 20000;
    final events = <_BenchEvent>[
      for (var index = 0; index < eventCount; index++)
        _BenchEvent(
          id: 'event-$index',
          source: 'source-${index % 96}',
          timestamp: index * 104729 % 10000019,
          kind: index % 11 == 0
              ? LogicalProjectionEventClass.crossChatReaction
              : index % 3 == 0
              ? LogicalProjectionEventClass.attachment
              : LogicalProjectionEventClass.normalMessage,
        ),
    ]..shuffle(Random(0x20000));
    final incremental = _projection();
    final stopwatch = Stopwatch()..start();
    for (final event in events) {
      incremental.upsert(event, eventClass: event.kind);
    }
    stopwatch.stop();
    final canonical = _projection()..rebuild(events);

    expect(incremental.values.map((event) => event.signature), canonical.values.map((event) => event.signature));
    // ignore: avoid_print
    print(
      'BENCH incremental_upsert events=$eventCount sources=96 ms=${stopwatch.elapsedMilliseconds} threshold_ms=8000',
    );
    expect(stopwatch.elapsedMilliseconds, lessThan(8000));
  });

  test('benchmark: maximum bounded identity snapshot round trip completes within 4 seconds', () {
    final logicalId = LogicalConversationId.certified('maximum-bounded-snapshot');
    final members = <PhysicalConversationRef>[
      for (var index = 0; index < LogicalConversationSnapshot.maxMembers; index++)
        PhysicalConversationRef.fromStablePhysicalGuid('member-$index'),
    ];
    final unread = LogicalUnreadLedger(certifiedSources: members);
    for (var index = 0; index < members.length; index++) {
      unread.observe(LogicalUnreadObservation(source: members[index], revision: index, hasUnread: index.isOdd));
    }
    final searches = <LogicalSearchResult>[
      for (var index = 0; index < LogicalConversationSnapshot.maxSearchResults; index++)
        LogicalSearchResult.fromStableMessageId(
          logicalId: logicalId,
          source: members[index % members.length],
          stableMessageId: 'message-$index',
          occurredAtEpochMicroseconds: index * 31 % 997,
        ),
    ];
    final media = <LogicalMediaItem>[
      for (var index = 0; index < LogicalConversationSnapshot.maxMediaItems; index++)
        LogicalMediaItem.fromStableIds(
          logicalId: logicalId,
          source: members[index % members.length],
          stableMessageId: 'message-$index',
          stableMediaId: 'attachment-$index',
          kind: LogicalMediaKind.values[index % LogicalMediaKind.values.length],
          availability: LogicalMediaAvailability.values[index % LogicalMediaAvailability.values.length],
          occurredAtEpochMicroseconds: index * 37 % 991,
        ),
    ];
    final stopwatch = Stopwatch()..start();
    final snapshot = LogicalConversationSnapshot(
      logicalId: logicalId,
      members: members.reversed,
      health: LogicalConversationHealth.readOnly,
      unreadLedger: unread,
      searchResults: searches.reversed,
      mediaItems: media.reversed,
      revision: 1,
    );
    final encoded = jsonEncode(snapshot.toJson());
    final restored = LogicalConversationSnapshot.fromJson((jsonDecode(encoded) as Map).cast<String, dynamic>());
    stopwatch.stop();

    expect(restored.fingerprint, snapshot.fingerprint);
    expect(restored.members, hasLength(LogicalConversationSnapshot.maxMembers));
    expect(restored.searchResults, hasLength(LogicalConversationSnapshot.maxSearchResults));
    expect(restored.mediaItems, hasLength(LogicalConversationSnapshot.maxMediaItems));
    // ignore: avoid_print
    print(
      'BENCH bounded_snapshot members=${members.length} search=${searches.length} media=${media.length} '
      'bytes=${encoded.length} ms=${stopwatch.elapsedMilliseconds} threshold_ms=4000',
    );
    expect(stopwatch.elapsedMilliseconds, lessThan(4000));
  });
}
