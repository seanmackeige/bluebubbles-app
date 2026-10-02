import 'dart:convert';

import 'package:bluebubbles/services/backend/java_dart_interop/notification_reply_operation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ten-thousand blocking tombstones remain bounded and restart-decodable', () {
    const count = 10000;
    final tombstones = <Map<String, Object>>[
      for (var index = 0; index < count; index++)
        <String, Object>{
          'operation_id': sha256.convert(utf8.encode('notification-reply-tombstone-$index')).toString(),
          'state': index.isEven ? 'terminal' : 'outcome_ambiguous',
        },
    ];
    final raw = jsonEncode(<String, Object>{
      'schema': notificationReplyOperationJournalSchema,
      'records': const <Object>[],
      'blocking_tombstones': tombstones,
    });

    final stopwatch = Stopwatch()..start();
    final restored = NotificationReplyOperationJournal.decode(raw);
    final canonical = restored.encode();
    stopwatch.stop();

    expect(restored.activeLength, 0);
    expect(restored.blockingTombstoneLength, count);
    expect(NotificationReplyOperationJournal.decode(canonical).blockingTombstoneLength, count);
    expect(utf8.encode(canonical).length, lessThan(1300000));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 4)));
  });
}
