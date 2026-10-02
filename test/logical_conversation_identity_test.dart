import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('opaque deterministic identity', () {
    test('certified and ordinary identities are deterministic, distinct, and retain no seed', () {
      const certifiedSeed = 'certified-source-set-alpha';
      const physicalSeed = 'physical-source-alpha';
      final certified = LogicalConversationId.certified(certifiedSeed);
      final ordinary = LogicalConversationId.ordinarySingleton(physicalSeed);

      expect(LogicalConversationId.certified(certifiedSeed), certified);
      expect(LogicalConversationId.ordinarySingleton(physicalSeed), ordinary);
      expect(certified, isNot(ordinary));
      expect(certified.isCertified, isTrue);
      expect(ordinary.isOrdinarySingleton, isTrue);
      expect(jsonEncode(certified.toJson()), isNot(contains(certifiedSeed)));
      expect(jsonEncode(ordinary.toJson()), isNot(contains(physicalSeed)));
      expect(LogicalConversationId.fromJson(certified.toJson()), certified);
      expect(LogicalConversationId.parse(ordinary.value), ordinary);
    });

    test('ordinary singleton identity is deterministic for every input ordering', () {
      final seeds = <String>['source-delta', 'source-alpha', 'source-charlie', 'source-beta'];
      final forward = <String, LogicalConversationId>{
        for (final seed in seeds) seed: LogicalConversationId.ordinarySingleton(seed),
      };
      final reverse = <String, LogicalConversationId>{
        for (final seed in seeds.reversed) seed: LogicalConversationId.ordinarySingleton(seed),
      };

      expect(reverse, forward);
      expect(forward.values.toSet(), hasLength(seeds.length));
    });

    test('malformed and unbounded inputs fail closed', () {
      expect(() => LogicalConversationId.parse('ordinary-source'), throwsFormatException);
      expect(() => LogicalConversationId.certified(''), throwsArgumentError);
      expect(() => LogicalConversationId.ordinarySingleton(List<String>.filled(4097, 'x').join()), throwsArgumentError);
      expect(
        () => LogicalConversationId.fromJson(<String, dynamic>{
          'schema': 'LOGICAL_CONVERSATION_ID_V0',
          'value': LogicalConversationId.certified('seed').value,
        }),
        throwsFormatException,
      );
    });
  });

  group('physical provenance and address', () {
    test('physical reference round trips without retaining its input', () {
      const seed = 'provider-source-alpha';
      final source = PhysicalConversationRef.fromStablePhysicalGuid(seed);

      expect(PhysicalConversationRef.fromJson(source.toJson()), source);
      expect(source.fingerprint, hasLength(64));
      expect(jsonEncode(source.toJson()), isNot(contains(seed)));
      expect(PhysicalConversationRef.fromStablePhysicalGuid('provider-source-beta'), isNot(source));
    });

    test('exact source and message anchor round trips through JSON and URI', () {
      const messageSeed = 'provider-message-alpha';
      final logicalId = LogicalConversationId.certified('certified-alpha');
      final source = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
      final address = ConversationAddress.logical(logicalId, source: source, stableMessageId: messageSeed);

      expect(ConversationAddress.fromJson(address.toJson()), address);
      expect(ConversationAddress.parseUri(address.toUri()), address);
      expect(address.hasExactSourceAnchor, isTrue);
      expect(address.hasExactMessageAnchor, isTrue);
      expect(address.compatibility, ConversationAddressCompatibility.logical);
      expect(jsonEncode(address.toJson()), isNot(contains(messageSeed)));
      expect(address.toUri().toString(), isNot(contains(messageSeed)));
    });

    test('source-only anchor is valid and message-without-source is rejected', () {
      final logicalId = LogicalConversationId.certified('certified-alpha');
      final source = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
      final address = ConversationAddress.logical(logicalId, source: source);

      expect(address.hasExactSourceAnchor, isTrue);
      expect(address.hasExactMessageAnchor, isFalse);
      expect(
        () => ConversationAddress.logical(logicalId, stableMessageId: 'message-without-source'),
        throwsArgumentError,
      );
    });

    test('legacy physical compatibility is explicit, opaque, and deterministic', () {
      const seed = 'legacy-physical-source';
      final first = ConversationAddress.legacyPhysicalGuid(seed, stableMessageId: 'legacy-message');
      final second = ConversationAddress.legacyPhysicalGuid(seed, stableMessageId: 'legacy-message');

      expect(first, second);
      expect(first.logicalId.isOrdinarySingleton, isTrue);
      expect(first.compatibility, ConversationAddressCompatibility.legacyPhysicalGuid);
      expect(first.hasExactMessageAnchor, isTrue);
      expect(jsonEncode(first.toJson()), isNot(contains(seed)));
      expect(ConversationAddress.parseUri(first.toUri()), first);
    });

    test('unsupported versions, fields, and fingerprints fail closed', () {
      final id = LogicalConversationId.certified('certified-alpha');
      expect(
        () => ConversationAddress.parseUri(Uri.parse('bluebubbles://conversation/v0/${id.value}')),
        throwsFormatException,
      );
      expect(
        () => ConversationAddress.parseUri(Uri.parse('bluebubbles://conversation/v1/${id.value}?unexpected=value')),
        throwsFormatException,
      );
      expect(() => PhysicalConversationRef.fromFingerprint('not-a-fingerprint'), throwsFormatException);
    });
  });

  group('derived logical health', () {
    test('derivation has deterministic fail-closed priority', () {
      LogicalConversationHealth derive({
        int available = 2,
        bool ready = true,
        bool partial = false,
        bool conflict = false,
      }) => LogicalConversationHealth.derive(
        certifiedSourceCount: 2,
        availableSourceCount: available,
        writeAuthorityReady: ready,
        partialReadAcknowledgement: partial,
        integrityConflict: conflict,
      );

      expect(derive(), LogicalConversationHealth.healthy);
      expect(derive(ready: false), LogicalConversationHealth.readOnly);
      expect(derive(partial: true), LogicalConversationHealth.partialReadAcknowledgement);
      expect(derive(available: 1, partial: true), LogicalConversationHealth.degraded);
      expect(derive(available: 1, conflict: true), LogicalConversationHealth.conflict);
    });

    test('impossible source cardinality is rejected', () {
      expect(
        () => LogicalConversationHealth.derive(
          certifiedSourceCount: 1,
          availableSourceCount: 2,
          writeAuthorityReady: false,
        ),
        throwsArgumentError,
      );
    });
  });

  group('monotonic per-source unread ledger', () {
    late PhysicalConversationRef sourceA;
    late PhysicalConversationRef sourceB;
    late PhysicalConversationRef foreign;
    late LogicalUnreadLedger ledger;

    setUp(() {
      sourceA = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
      sourceB = PhysicalConversationRef.fromStablePhysicalGuid('source-beta');
      foreign = PhysicalConversationRef.fromStablePhysicalGuid('source-foreign');
      ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[sourceB, sourceA]);
    });

    test('member order is canonical and stale observations are ignored', () {
      expect(ledger.certifiedSources, orderedEquals(<PhysicalConversationRef>[sourceA, sourceB]..sort()));
      expect(
        ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 10, hasUnread: true)),
        LogicalUnreadObservationResult.advanced,
      );
      expect(
        ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 9, hasUnread: false)),
        LogicalUnreadObservationResult.staleIgnored,
      );
      expect(
        ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 10, hasUnread: true)),
        LogicalUnreadObservationResult.unchanged,
      );
      expect(ledger.observationFor(sourceA)!.revision, 10);
    });

    test('same-revision contradiction and foreign source fail closed', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 10, hasUnread: true));
      expect(
        () => ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 10, hasUnread: false)),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('SAME_REVISION_CONFLICT'))),
      );
      expect(
        () => ledger.observe(LogicalUnreadObservation(source: foreign, revision: 1, hasUnread: true)),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('OUTSIDE_CERTIFICATE'))),
      );
    });

    test('mark-read plan contains only unread exact sources', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 10, hasUnread: true));
      ledger.observe(LogicalUnreadObservation(source: sourceB, revision: 20, hasUnread: false));

      final plan = ledger.markReadPlan();
      expect(plan.entries, hasLength(1));
      expect(plan.entries.single.source, sourceA);
      expect(plan.entries.single.observedRevision, 10);
    });

    test('partial receipts retain unread while preserving successful source progress', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 10, hasUnread: true));
      ledger.observe(LogicalUnreadObservation(source: sourceB, revision: 20, hasUnread: true));
      final plan = ledger.markReadPlan();
      final outcome = ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
        LogicalMarkReadReceipt.success(source: sourceA, plannedRevision: 10, resultRevision: 11),
        LogicalMarkReadReceipt.failure(source: sourceB, plannedRevision: 20),
      ]);

      expect(outcome, LogicalMarkReadOutcome.partial);
      expect(ledger.hasUnread, isTrue);
      expect(ledger.observationFor(sourceA)!.hasUnread, isFalse);
      expect(ledger.observationFor(sourceA)!.revision, 11);
      expect(ledger.markReadPlan().entries.single.source, sourceB);
    });

    test('all successful receipts complete the exact plan', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 1, hasUnread: true));
      ledger.observe(LogicalUnreadObservation(source: sourceB, revision: 2, hasUnread: true));
      final plan = ledger.markReadPlan();
      final outcome = ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
        LogicalMarkReadReceipt.success(source: sourceB, plannedRevision: 2, resultRevision: 4),
        LogicalMarkReadReceipt.success(source: sourceA, plannedRevision: 1, resultRevision: 3),
      ]);

      expect(outcome, LogicalMarkReadOutcome.complete);
      expect(ledger.hasUnread, isFalse);
      expect(ledger.markReadPlan().isEmpty, isTrue);
    });

    test('state drift invalidates an old plan', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 1, hasUnread: true));
      final stalePlan = ledger.markReadPlan();
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 2, hasUnread: true));
      expect(
        () => ledger.applyMarkReadReceipts(stalePlan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.success(source: sourceA, plannedRevision: 1, resultRevision: 3),
        ]),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('PLAN_STALE'))),
      );
    });

    test('outside-plan, duplicate, and nonadvancing receipts are rejected', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 1, hasUnread: true));
      final plan = ledger.markReadPlan();
      expect(
        () => LogicalMarkReadReceipt.success(source: sourceA, plannedRevision: 1, resultRevision: 1),
        throwsArgumentError,
      );
      expect(
        () => ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.failure(source: foreign, plannedRevision: 1),
        ]),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('OUTSIDE_PLAN'))),
      );
      expect(
        () => ledger.applyMarkReadReceipts(plan, <LogicalMarkReadReceipt>[
          LogicalMarkReadReceipt.failure(source: sourceA, plannedRevision: 1),
          LogicalMarkReadReceipt.failure(source: sourceA, plannedRevision: 1),
        ]),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('DUPLICATE_RECEIPT'))),
      );
    });

    test('JSON reconstruction preserves state and duplicate observations fail closed', () {
      ledger.observe(LogicalUnreadObservation(source: sourceA, revision: 7, hasUnread: true));
      ledger.observe(LogicalUnreadObservation(source: sourceB, revision: 8, hasUnread: false));
      final restored = LogicalUnreadLedger.fromJson(_jsonRoundTrip(ledger.toJson()));
      expect(restored.toJson(), ledger.toJson());

      final observation = LogicalUnreadObservation(source: sourceA, revision: 1, hasUnread: true).toJson();
      expect(
        () => LogicalUnreadLedger.fromJson(<String, dynamic>{
          'schema': logicalUnreadLedgerSchema,
          'certifiedSources': <String>[sourceA.fingerprint],
          'observations': <Map<String, dynamic>>[observation, observation],
        }),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('DUPLICATE_SOURCE'))),
      );
    });
  });

  group('notification, provenance DTOs, and bounded snapshot', () {
    test('notification key and disjoint negative Android ID are stable', () {
      final logicalId = LogicalConversationId.certified('certified-alpha');
      final first = LogicalNotificationIdentity.fromLogicalId(logicalId);
      final second = LogicalNotificationIdentity.fromLogicalId(LogicalConversationId.parse(logicalId.value));

      expect(second, first);
      expect(first.androidId, lessThan(0));
      expect(first.androidId, greaterThanOrEqualTo(-0x7fffffff));
      expect(LogicalNotificationIdentity.fromJson(first.toJson(), logicalId), first);
      expect(
        () => LogicalNotificationIdentity.fromJson(<String, dynamic>{
          ...first.toJson(),
          'androidId': first.androidId + 1,
        }, logicalId),
        throwsFormatException,
      );
    });

    test('search and media DTOs retain exact provenance without content', () {
      final logicalId = LogicalConversationId.certified('certified-alpha');
      final source = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
      final search = LogicalSearchResult.fromStableMessageId(
        logicalId: logicalId,
        source: source,
        stableMessageId: 'message-alpha',
        occurredAtEpochMicroseconds: 100,
      );
      final media = LogicalMediaItem.fromStableIds(
        logicalId: logicalId,
        source: source,
        stableMessageId: 'message-alpha',
        stableMediaId: 'media-alpha',
        kind: LogicalMediaKind.photo,
        availability: LogicalMediaAvailability.available,
        occurredAtEpochMicroseconds: 100,
      );

      expect(LogicalSearchResult.fromJson(search.toJson()).toJson(), search.toJson());
      expect(LogicalMediaItem.fromJson(media.toJson()).toJson(), media.toJson());
      expect(search.address, media.owningMessageAddress);
      expect(search.toJson().keys, isNot(contains('text')));
      expect(media.toJson().keys, isNot(contains('name')));
    });

    test('member and item order do not alter canonical snapshot identity', () {
      final fixture = _snapshotFixture();
      final reversed = LogicalConversationSnapshot(
        logicalId: fixture.logicalId,
        members: fixture.members.reversed,
        health: fixture.health,
        unreadLedger: fixture.unreadLedger,
        searchResults: fixture.searchResults.reversed,
        mediaItems: fixture.mediaItems.reversed,
        revision: fixture.revision,
      );

      expect(reversed.toJson(), fixture.toJson());
      expect(reversed.fingerprint, fixture.fingerprint);
    });

    test('snapshot survives cache reconstruction and does not expose mutable ledger state', () {
      final original = _snapshotFixture();
      final restored = LogicalConversationSnapshot.fromJson(_jsonRoundTrip(original.toJson()));
      final detachedLedger = restored.unreadLedger;
      final unreadSource = detachedLedger.markReadPlan().entries.single.source;
      detachedLedger.observe(LogicalUnreadObservation(source: unreadSource, revision: 99, hasUnread: false));

      expect(restored.toJson(), original.toJson());
      expect(restored.fingerprint, original.fingerprint);
      expect(restored.unreadLedger.hasUnread, isTrue);
    });

    test('foreign search and media provenance fail closed', () {
      final logicalId = LogicalConversationId.certified('certified-alpha');
      final member = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
      final foreign = PhysicalConversationRef.fromStablePhysicalGuid('source-foreign');
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[member]);
      final foreignSearch = LogicalSearchResult.fromStableMessageId(
        logicalId: logicalId,
        source: foreign,
        stableMessageId: 'message-foreign',
        occurredAtEpochMicroseconds: 1,
      );
      final foreignMedia = LogicalMediaItem.fromStableIds(
        logicalId: logicalId,
        source: foreign,
        stableMessageId: 'message-foreign',
        stableMediaId: 'media-foreign',
        kind: LogicalMediaKind.other,
        availability: LogicalMediaAvailability.unavailable,
        occurredAtEpochMicroseconds: 1,
      );

      expect(
        () => _snapshot(logicalId, member, ledger, search: <LogicalSearchResult>[foreignSearch]),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('SEARCH_PROVENANCE'))),
      );
      expect(
        () => _snapshot(logicalId, member, ledger, media: <LogicalMediaItem>[foreignMedia]),
        throwsA(isA<StateError>().having((error) => error.toString(), 'reason', contains('MEDIA_PROVENANCE'))),
      );
    });

    test('empty and oversized snapshots are rejected', () {
      final logicalId = LogicalConversationId.certified('certified-alpha');
      final source = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
      final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[source]);
      expect(
        () => LogicalConversationSnapshot(
          logicalId: logicalId,
          members: const <PhysicalConversationRef>[],
          health: LogicalConversationHealth.readOnly,
          unreadLedger: ledger,
          searchResults: const <LogicalSearchResult>[],
          mediaItems: const <LogicalMediaItem>[],
          revision: 1,
        ),
        throwsArgumentError,
      );

      final oversized = <LogicalSearchResult>[
        for (var index = 0; index <= LogicalConversationSnapshot.maxSearchResults; index++)
          LogicalSearchResult.fromStableMessageId(
            logicalId: logicalId,
            source: source,
            stableMessageId: 'message-$index',
            occurredAtEpochMicroseconds: index,
          ),
      ];
      expect(() => _snapshot(logicalId, source, ledger, search: oversized), throwsArgumentError);
    });
  });
}

LogicalConversationSnapshot _snapshotFixture() {
  final logicalId = LogicalConversationId.certified('certified-alpha');
  final sourceA = PhysicalConversationRef.fromStablePhysicalGuid('source-alpha');
  final sourceB = PhysicalConversationRef.fromStablePhysicalGuid('source-beta');
  final ledger = LogicalUnreadLedger(certifiedSources: <PhysicalConversationRef>[sourceB, sourceA])
    ..observe(LogicalUnreadObservation(source: sourceA, revision: 2, hasUnread: true))
    ..observe(LogicalUnreadObservation(source: sourceB, revision: 3, hasUnread: false));
  return LogicalConversationSnapshot(
    logicalId: logicalId,
    members: <PhysicalConversationRef>[sourceB, sourceA],
    health: LogicalConversationHealth.readOnly,
    unreadLedger: ledger,
    searchResults: <LogicalSearchResult>[
      LogicalSearchResult.fromStableMessageId(
        logicalId: logicalId,
        source: sourceB,
        stableMessageId: 'message-beta',
        occurredAtEpochMicroseconds: 20,
      ),
      LogicalSearchResult.fromStableMessageId(
        logicalId: logicalId,
        source: sourceA,
        stableMessageId: 'message-alpha',
        occurredAtEpochMicroseconds: 10,
      ),
    ],
    mediaItems: <LogicalMediaItem>[
      LogicalMediaItem.fromStableIds(
        logicalId: logicalId,
        source: sourceB,
        stableMessageId: 'message-beta',
        stableMediaId: 'media-beta',
        kind: LogicalMediaKind.file,
        availability: LogicalMediaAvailability.unavailable,
        occurredAtEpochMicroseconds: 20,
      ),
      LogicalMediaItem.fromStableIds(
        logicalId: logicalId,
        source: sourceA,
        stableMessageId: 'message-alpha',
        stableMediaId: 'media-alpha',
        kind: LogicalMediaKind.photo,
        availability: LogicalMediaAvailability.available,
        occurredAtEpochMicroseconds: 10,
      ),
    ],
    revision: 4,
  );
}

LogicalConversationSnapshot _snapshot(
  LogicalConversationId logicalId,
  PhysicalConversationRef member,
  LogicalUnreadLedger ledger, {
  List<LogicalSearchResult> search = const <LogicalSearchResult>[],
  List<LogicalMediaItem> media = const <LogicalMediaItem>[],
}) {
  return LogicalConversationSnapshot(
    logicalId: logicalId,
    members: <PhysicalConversationRef>[member],
    health: LogicalConversationHealth.readOnly,
    unreadLedger: ledger,
    searchResults: search,
    mediaItems: media,
    revision: 1,
  );
}

Map<String, dynamic> _jsonRoundTrip(Map<String, dynamic> value) {
  return (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();
}
