import 'dart:async';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final firstId = LogicalConversationId.certified('first-certified-conversation');
  final secondId = LogicalConversationId.certified('second-certified-conversation');

  test('transaction queue prevents concurrent multi-ID lost updates and survives restart', () async {
    final queue = LogicalConversationSettingsTransactionQueue();
    var published = LogicalConversationSettingsLedger.empty();
    final firstPersistStarted = Completer<void>();
    final releaseFirstPersist = Completer<void>();

    Future<void> commitMuted(LogicalConversationId id, {bool delayPersistence = false}) => queue.run(() async {
      final revision = published.forId(id)?.revision ?? 0;
      final operation = LogicalConversationSettingsMutation(
        operationId: published.operationId(logicalId: id, expectedRevision: revision, kind: 'mute', value: true),
        expectedRevision: revision,
        isMuted: true,
      );
      final result = await commitLogicalConversationSettingsMutation(
        current: published,
        logicalId: id,
        mutation: operation,
        persist: (_) async {
          if (delayPersistence) {
            firstPersistStarted.complete();
            await releaseFirstPersist.future;
          }
        },
      );
      expect(result.committed, isTrue);
      published = result.ledger;
    });

    final first = commitMuted(firstId, delayPersistence: true);
    await firstPersistStarted.future;
    final second = commitMuted(secondId);
    await Future<void>.delayed(Duration.zero);
    expect(published.forId(secondId), isNull);
    releaseFirstPersist.complete();
    await Future.wait(<Future<void>>[first, second]);

    final restored = LogicalConversationSettingsLedger.decode(published.encode());
    expect(restored.forId(firstId)?.isMuted, isTrue);
    expect(restored.forId(secondId)?.isMuted, isTrue);
  });

  test('serialized custom-group deltas merge against the latest committed set', () async {
    final queue = LogicalConversationSettingsTransactionQueue();
    var published = LogicalConversationSettingsLedger.empty();
    published.migrateIfAbsent(LogicalConversationSettings(logicalId: firstId, customGroupIds: <int>{1}));

    Future<void> applyDelta(int groupId) => queue.run(() async {
      final current = published.forId(firstId)!;
      final groups = applyLogicalCustomGroupDelta(current: current.customGroupIds, groupId: groupId, included: true);
      final operation = LogicalConversationSettingsMutation(
        operationId: published.operationId(
          logicalId: firstId,
          expectedRevision: current.revision,
          kind: 'custom-groups',
          value: groups.toList()..sort(),
        ),
        expectedRevision: current.revision,
        customGroupIds: groups,
      );
      final result = await commitLogicalConversationSettingsMutation(
        current: published,
        logicalId: firstId,
        mutation: operation,
        persist: (_) async => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      expect(result.committed, isTrue);
      published = result.ledger;
    });

    await Future.wait(<Future<void>>[applyDelta(2), applyDelta(3)]);
    expect(published.forId(firstId)?.customGroupIds, <int>{1, 2, 3});
    expect(LogicalConversationSettingsLedger.decode(published.encode()).forId(firstId)?.customGroupIds, <int>{1, 2, 3});
  });
}
