import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final logicalId = LogicalConversationId.certified('certified-conversation-fixture');

  LogicalConversationSettingsMutation mutation(
    LogicalConversationSettingsLedger ledger,
    String kind,
    Object? value, {
    bool? isPinned,
    int? pinIndex,
    bool clearPinIndex = false,
    bool? isArchived,
    bool? isMuted,
    Set<int>? customGroupIds,
  }) {
    final revision = ledger.forId(logicalId)?.revision ?? 0;
    return LogicalConversationSettingsMutation(
      operationId: ledger.operationId(logicalId: logicalId, expectedRevision: revision, kind: kind, value: value),
      expectedRevision: revision,
      isPinned: isPinned,
      pinIndex: pinIndex,
      clearPinIndex: clearPinIndex,
      isArchived: isArchived,
      isMuted: isMuted,
      customGroupIds: customGroupIds,
    );
  }

  test('settings are keyed only by canonical certified logical identity', () {
    final settings = LogicalConversationSettings(logicalId: logicalId, isMuted: true);
    final encoded = jsonEncode(settings.toJson());
    expect(encoded, contains(logicalId.value));
    expect(encoded, isNot(contains('certified-conversation-fixture')));
    expect(
      () => LogicalConversationSettings(logicalId: LogicalConversationId.ordinarySingleton('guid')),
      throwsArgumentError,
    );
  });

  test('pin archive mute and custom groups survive restart reconstruction', () {
    final ledger = LogicalConversationSettingsLedger.empty();
    expect(ledger.apply(logicalId, mutation(ledger, 'pin', true, isPinned: true, pinIndex: 4)).applied, isTrue);
    expect(ledger.apply(logicalId, mutation(ledger, 'archive', true, isArchived: true)).applied, isTrue);
    expect(ledger.apply(logicalId, mutation(ledger, 'mute', true, isMuted: true)).applied, isTrue);
    expect(
      ledger.apply(logicalId, mutation(ledger, 'groups', <int>[3, 7], customGroupIds: <int>{7, 3})).applied,
      isTrue,
    );

    final restored = LogicalConversationSettingsLedger.decode(ledger.encode());
    final settings = restored.forId(logicalId)!;
    expect(restored.isCorrupt, isFalse);
    expect(settings.revision, 4);
    expect(settings.isPinned, isTrue);
    expect(settings.pinIndex, 4);
    expect(settings.isArchived, isTrue);
    expect(settings.isMuted, isTrue);
    expect(settings.customGroupIds, <int>{3, 7});
  });

  test('duplicate operations are replay safe and stale revisions fail closed', () {
    final ledger = LogicalConversationSettingsLedger.empty();
    final operation = mutation(ledger, 'mute', true, isMuted: true);
    final first = ledger.apply(logicalId, operation);
    final replay = ledger.apply(logicalId, operation);
    expect(first.applied, isTrue);
    expect(replay.applied, isFalse);
    expect(replay.duplicate, isTrue);
    expect(replay.settings.revision, 1);

    final stale = ledger.apply(
      logicalId,
      const LogicalConversationSettingsMutation(operationId: 'stale-operation', expectedRevision: 0, isArchived: true),
    );
    expect(stale.revisionConflict, isTrue);
    expect(stale.settings.isArchived, isFalse);
    expect(stale.settings.revision, 1);
  });

  test('migration is one-time and later provider provenance cannot overwrite human intent', () {
    final ledger = LogicalConversationSettingsLedger.empty();
    expect(
      ledger.migrateIfAbsent(
        LogicalConversationSettings(
          logicalId: logicalId,
          isPinned: true,
          pinIndex: 2,
          isMuted: true,
          customGroupIds: <int>{9},
          migratedFromPhysicalProvenance: true,
        ),
      ),
      isTrue,
    );
    expect(
      ledger.migrateIfAbsent(
        LogicalConversationSettings(logicalId: logicalId, isArchived: true, migratedFromPhysicalProvenance: true),
      ),
      isFalse,
    );
    final settings = ledger.forId(logicalId)!;
    expect(settings.isPinned, isTrue);
    expect(settings.isArchived, isFalse);
    expect(settings.isMuted, isTrue);
    expect(settings.customGroupIds, <int>{9});
  });

  test('corrupt ledger rejects mutation without replacing persisted intent', () {
    final ledger = LogicalConversationSettingsLedger.decode('{bad-json');
    expect(ledger.isCorrupt, isTrue);
    final result = ledger.apply(
      logicalId,
      const LogicalConversationSettingsMutation(operationId: 'operation', expectedRevision: 0, isMuted: true),
    );
    expect(result.applied, isFalse);
    expect(result.revisionConflict, isTrue);
  });

  test('serialization is deterministic across custom-group ordering', () {
    final first = LogicalConversationSettingsLedger.empty();
    first.migrateIfAbsent(LogicalConversationSettings(logicalId: logicalId, customGroupIds: <int>{7, 2, 5}));
    final second = LogicalConversationSettingsLedger.empty();
    second.migrateIfAbsent(LogicalConversationSettings(logicalId: logicalId, customGroupIds: <int>{5, 7, 2}));
    expect(first.encode(), second.encode());
  });

  test('migration imports only exact all-mute and preserves specialized policy', () {
    expect(migrateLogicalAllMuteFromPhysicalProvenance(null), isFalse);
    expect(migrateLogicalAllMuteFromPhysicalProvenance('mute'), isTrue);
    for (final specialized in <String>['mute_individuals', 'temporary_mute', 'text_detection']) {
      expect(migrateLogicalAllMuteFromPhysicalProvenance(specialized), isFalse);
      expect(shouldPreserveSpecializedPhysicalMute(specialized), isTrue);
    }
    expect(shouldPreserveSpecializedPhysicalMute(null), isFalse);
    expect(shouldPreserveSpecializedPhysicalMute('mute'), isFalse);
  });

  test('logical mute overlay preserves global text and reaction policy', () {
    expect(
      shouldMuteLogicalConversationNotification(
        logicalAllMuted: false,
        unknownSenderFiltered: true,
        globalTextDetection: '',
        messageText: 'hello',
        notifyReactions: true,
        isReaction: false,
      ),
      isTrue,
    );
    expect(
      shouldMuteLogicalConversationNotification(
        logicalAllMuted: true,
        unknownSenderFiltered: false,
        globalTextDetection: 'urgent',
        messageText: 'URGENT update',
        notifyReactions: true,
        isReaction: false,
      ),
      isFalse,
    );
    expect(
      shouldMuteLogicalConversationNotification(
        logicalAllMuted: false,
        unknownSenderFiltered: false,
        globalTextDetection: '',
        messageText: 'reaction',
        notifyReactions: false,
        isReaction: true,
      ),
      isTrue,
    );
  });

  test('failed durable write never publishes mutated logical settings', () async {
    final ledger = LogicalConversationSettingsLedger.empty();
    final operation = mutation(ledger, 'mute', true, isMuted: true);
    final result = await commitLogicalConversationSettingsMutation(
      current: ledger,
      logicalId: logicalId,
      mutation: operation,
      persist: (_) async => throw StateError('injected persistence failure'),
    );

    expect(result.committed, isFalse);
    expect(result.failure, isA<StateError>());
    expect(identical(result.ledger, ledger), isTrue);
    expect(ledger.forId(logicalId), isNull);
  });

  test('successful durable write atomically publishes the detached ledger', () async {
    final ledger = LogicalConversationSettingsLedger.empty();
    final operation = mutation(ledger, 'archive', true, isArchived: true);
    String? persisted;
    final result = await commitLogicalConversationSettingsMutation(
      current: ledger,
      logicalId: logicalId,
      mutation: operation,
      persist: (encoded) async {
        persisted = encoded;
      },
    );

    expect(result.committed, isTrue);
    expect(result.failure, isNull);
    expect(identical(result.ledger, ledger), isFalse);
    expect(ledger.forId(logicalId), isNull);
    expect(result.ledger.forId(logicalId)?.isArchived, isTrue);
    expect(persisted, result.ledger.encode());
  });

  test('settings migration persists before publishing and rolls back on failure', () async {
    final ledger = LogicalConversationSettingsLedger.empty();
    final migration = LogicalConversationSettings(
      logicalId: logicalId,
      isPinned: true,
      pinIndex: 3,
      migratedFromPhysicalProvenance: true,
    );

    final failed = await commitLogicalConversationSettingsMigrations(
      current: ledger,
      migrations: <LogicalConversationSettings>[migration],
      persist: (_) async => throw StateError('injected migration persistence failure'),
    );
    expect(failed.committed, isFalse);
    expect(failed.failure, isA<StateError>());
    expect(identical(failed.ledger, ledger), isTrue);
    expect(ledger.forId(logicalId), isNull);

    String? persisted;
    final committed = await commitLogicalConversationSettingsMigrations(
      current: ledger,
      migrations: <LogicalConversationSettings>[migration],
      persist: (encoded) async => persisted = encoded,
    );
    expect(committed.committed, isTrue);
    expect(committed.changed, isTrue);
    expect(identical(committed.ledger, ledger), isFalse);
    expect(committed.ledger.forId(logicalId)?.pinIndex, 3);
    expect(persisted, committed.ledger.encode());
  });

  test('settings migration is idempotent without rewriting durable state', () async {
    final ledger = LogicalConversationSettingsLedger.empty();
    ledger.migrateIfAbsent(LogicalConversationSettings(logicalId: logicalId, migratedFromPhysicalProvenance: true));
    var writes = 0;
    final result = await commitLogicalConversationSettingsMigrations(
      current: ledger,
      migrations: <LogicalConversationSettings>[
        LogicalConversationSettings(logicalId: logicalId, isMuted: true, migratedFromPhysicalProvenance: true),
      ],
      persist: (_) async => writes += 1,
    );
    expect(result.committed, isTrue);
    expect(result.changed, isFalse);
    expect(identical(result.ledger, ledger), isTrue);
    expect(writes, 0);
  });

  test('migration presentation selection never falls back to a sibling', () {
    final sources = <({int rowId, String name})>[(rowId: 11, name: 'sibling'), (rowId: 12, name: 'presentation')];
    expect(
      exactLogicalSettingsMigrationPresentation(
        sources,
        presentationSourceRowId: 12,
        sourceRowIdOf: (source) => source.rowId,
      )?.name,
      'presentation',
    );
    expect(
      exactLogicalSettingsMigrationPresentation(
        sources.where((source) => source.rowId == 11),
        presentationSourceRowId: 12,
        sourceRowIdOf: (source) => source.rowId,
      ),
      isNull,
    );
  });
}
