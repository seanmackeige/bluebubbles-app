import 'dart:convert';

import 'package:crypto/crypto.dart';

const logicalConversationIdSchema = 'LOGICAL_CONVERSATION_ID_V1';
const physicalConversationRefSchema = 'PHYSICAL_CONVERSATION_REF_V1';
const conversationAddressSchema = 'CONVERSATION_ADDRESS_V1';
const logicalUnreadLedgerSchema = 'LOGICAL_UNREAD_LEDGER_V1';
const logicalSearchResultSchema = 'LOGICAL_SEARCH_RESULT_V1';
const logicalMediaItemSchema = 'LOGICAL_MEDIA_ITEM_V1';
const logicalConversationSnapshotSchema = 'LOGICAL_CONVERSATION_SNAPSHOT_V1';

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _logicalIdPattern = RegExp(r'^lc\.v1\.(certified|ordinary)\.[0-9a-f]{64}$');

String _stableFingerprint(String namespace, Iterable<String> components) {
  final material = jsonEncode(<String, dynamic>{
    'schema': logicalConversationIdSchema,
    'namespace': namespace,
    'components': components.toList(growable: false),
  });
  return sha256.convert(utf8.encode(material)).toString();
}

String _boundedSeed(String value, String name) {
  if (value.isEmpty || value.length > 4096) {
    throw ArgumentError.value(value.length, name, 'must contain between 1 and 4096 characters');
  }
  return value;
}

String _requireFingerprint(String value, String name) {
  if (!_sha256Pattern.hasMatch(value)) {
    throw FormatException('$name must be a lowercase SHA-256 fingerprint');
  }
  return value;
}

/// Opaque human-conversation identity. Source seeds are hashed immediately and
/// are never retained in the value or its serialized form.
class LogicalConversationId implements Comparable<LogicalConversationId> {
  const LogicalConversationId._(this.value);

  factory LogicalConversationId.certified(String stableCertifiedId) {
    final digest = _stableFingerprint('certified-logical-conversation', <String>[
      _boundedSeed(stableCertifiedId, 'stableCertifiedId'),
    ]);
    return LogicalConversationId._('lc.v1.certified.$digest');
  }

  factory LogicalConversationId.ordinarySingleton(String stablePhysicalGuid) {
    final digest = _stableFingerprint('ordinary-singleton-conversation', <String>[
      _boundedSeed(stablePhysicalGuid, 'stablePhysicalGuid'),
    ]);
    return LogicalConversationId._('lc.v1.ordinary.$digest');
  }

  factory LogicalConversationId.parse(String value) {
    if (!_logicalIdPattern.hasMatch(value)) {
      throw const FormatException('Unsupported logical conversation identity');
    }
    return LogicalConversationId._(value);
  }

  factory LogicalConversationId.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalConversationIdSchema) {
      throw const FormatException('Unsupported logical conversation identity schema');
    }
    return LogicalConversationId.parse(json['value'] as String);
  }

  final String value;

  bool get isCertified => value.startsWith('lc.v1.certified.');
  bool get isOrdinarySingleton => value.startsWith('lc.v1.ordinary.');

  Map<String, dynamic> toJson() => <String, dynamic>{'schema': logicalConversationIdSchema, 'value': value};

  @override
  int compareTo(LogicalConversationId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is LogicalConversationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// Exact physical source provenance represented only by a stable, privacy-safe
/// fingerprint. The raw provider GUID is consumed at construction and discarded.
class PhysicalConversationRef implements Comparable<PhysicalConversationRef> {
  const PhysicalConversationRef._(this.fingerprint);

  factory PhysicalConversationRef.fromStablePhysicalGuid(String stablePhysicalGuid) {
    return PhysicalConversationRef._(
      _stableFingerprint('physical-conversation', <String>[_boundedSeed(stablePhysicalGuid, 'stablePhysicalGuid')]),
    );
  }

  factory PhysicalConversationRef.fromFingerprint(String fingerprint) {
    return PhysicalConversationRef._(_requireFingerprint(fingerprint, 'physical conversation fingerprint'));
  }

  factory PhysicalConversationRef.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != physicalConversationRefSchema) {
      throw const FormatException('Unsupported physical conversation reference schema');
    }
    return PhysicalConversationRef.fromFingerprint(json['fingerprint'] as String);
  }

  final String fingerprint;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': physicalConversationRefSchema,
    'fingerprint': fingerprint,
  };

  @override
  int compareTo(PhysicalConversationRef other) => fingerprint.compareTo(other.fingerprint);

  @override
  bool operator ==(Object other) => other is PhysicalConversationRef && other.fingerprint == fingerprint;

  @override
  int get hashCode => fingerprint.hashCode;

  @override
  String toString() => fingerprint;
}

enum ConversationAddressCompatibility { logical, legacyPhysicalGuid }

/// Stable navigation address. An optional message anchor is meaningful only
/// together with its exact physical source fingerprint.
class ConversationAddress {
  ConversationAddress._({required this.logicalId, required this.compatibility, this.source, this.messageFingerprint}) {
    if (messageFingerprint != null && source == null) {
      throw ArgumentError('An exact message anchor requires physical source provenance');
    }
    if (messageFingerprint != null) {
      _requireFingerprint(messageFingerprint!, 'message fingerprint');
    }
    if (compatibility == ConversationAddressCompatibility.legacyPhysicalGuid && source == null) {
      throw ArgumentError('Legacy physical compatibility requires a physical source');
    }
  }

  factory ConversationAddress.logical(
    LogicalConversationId logicalId, {
    PhysicalConversationRef? source,
    String? stableMessageId,
  }) {
    return ConversationAddress._(
      logicalId: logicalId,
      compatibility: ConversationAddressCompatibility.logical,
      source: source,
      messageFingerprint: stableMessageId == null
          ? null
          : _stableFingerprint('logical-message-anchor', <String>[
              source?.fingerprint ?? (throw ArgumentError('stableMessageId requires source')),
              _boundedSeed(stableMessageId, 'stableMessageId'),
            ]),
    );
  }

  /// Explicit compatibility bridge for old callers that only know a physical
  /// GUID. It produces the same ordinary logical ID every time and retains no
  /// raw GUID in the resulting address.
  factory ConversationAddress.legacyPhysicalGuid(String stablePhysicalGuid, {String? stableMessageId}) {
    final source = PhysicalConversationRef.fromStablePhysicalGuid(stablePhysicalGuid);
    return ConversationAddress._(
      logicalId: LogicalConversationId.ordinarySingleton(stablePhysicalGuid),
      compatibility: ConversationAddressCompatibility.legacyPhysicalGuid,
      source: source,
      messageFingerprint: stableMessageId == null
          ? null
          : _stableFingerprint('logical-message-anchor', <String>[
              source.fingerprint,
              _boundedSeed(stableMessageId, 'stableMessageId'),
            ]),
    );
  }

  factory ConversationAddress.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != conversationAddressSchema) {
      throw const FormatException('Unsupported conversation address schema');
    }
    final compatibilityName = json['compatibility'] as String;
    final compatibility = ConversationAddressCompatibility.values
        .where((candidate) => candidate.name == compatibilityName)
        .firstOrNull;
    if (compatibility == null) throw const FormatException('Unsupported conversation address compatibility');
    final rawSource = json['source'];
    if (rawSource != null && rawSource is! Map) {
      throw const FormatException('Malformed conversation address source');
    }
    return ConversationAddress._(
      logicalId: LogicalConversationId.parse(json['logicalId'] as String),
      compatibility: compatibility,
      source: rawSource == null ? null : PhysicalConversationRef.fromJson(rawSource.cast<String, dynamic>()),
      messageFingerprint: json['messageFingerprint'] as String?,
    );
  }

  factory ConversationAddress.parseUri(Uri uri) {
    if (uri.scheme != 'bluebubbles' || uri.host != 'conversation' || uri.pathSegments.length != 2) {
      throw const FormatException('Unsupported conversation address URI');
    }
    if (uri.pathSegments.first != 'v1') throw const FormatException('Unsupported conversation address URI version');
    const supportedQueryKeys = <String>{'compatibility', 'source', 'message'};
    if (uri.queryParameters.keys.any((key) => !supportedQueryKeys.contains(key))) {
      throw const FormatException('Unsupported conversation address URI field');
    }
    final compatibilityName = uri.queryParameters['compatibility'] ?? ConversationAddressCompatibility.logical.name;
    final compatibility = ConversationAddressCompatibility.values
        .where((candidate) => candidate.name == compatibilityName)
        .firstOrNull;
    if (compatibility == null) throw const FormatException('Unsupported conversation address compatibility');
    final sourceValue = uri.queryParameters['source'];
    return ConversationAddress._(
      logicalId: LogicalConversationId.parse(uri.pathSegments.last),
      compatibility: compatibility,
      source: sourceValue == null ? null : PhysicalConversationRef.fromFingerprint(sourceValue),
      messageFingerprint: uri.queryParameters['message'],
    );
  }

  final LogicalConversationId logicalId;
  final ConversationAddressCompatibility compatibility;
  final PhysicalConversationRef? source;
  final String? messageFingerprint;

  bool get hasExactSourceAnchor => source != null;
  bool get hasExactMessageAnchor => source != null && messageFingerprint != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': conversationAddressSchema,
    'logicalId': logicalId.value,
    'compatibility': compatibility.name,
    if (source != null) 'source': source!.toJson(),
    if (messageFingerprint != null) 'messageFingerprint': messageFingerprint,
  };

  Uri toUri() => Uri(
    scheme: 'bluebubbles',
    host: 'conversation',
    pathSegments: <String>['v1', logicalId.value],
    queryParameters: <String, String>{
      'compatibility': compatibility.name,
      'source': ?source?.fingerprint,
      'message': ?messageFingerprint,
    },
  );

  @override
  bool operator ==(Object other) =>
      other is ConversationAddress &&
      other.logicalId == logicalId &&
      other.compatibility == compatibility &&
      other.source == source &&
      other.messageFingerprint == messageFingerprint;

  @override
  int get hashCode => Object.hash(logicalId, compatibility, source, messageFingerprint);
}

/// Compact presentation health. It is explanatory state only and grants no
/// execution authority.
enum LogicalConversationHealth {
  healthy,
  readOnly,
  partialReadAcknowledgement,
  degraded,
  conflict;

  static LogicalConversationHealth derive({
    required int certifiedSourceCount,
    required int availableSourceCount,
    required bool writeAuthorityReady,
    bool partialReadAcknowledgement = false,
    bool integrityConflict = false,
  }) {
    if (certifiedSourceCount <= 0 || availableSourceCount < 0 || availableSourceCount > certifiedSourceCount) {
      throw ArgumentError('Invalid certified/available source cardinality');
    }
    if (integrityConflict) return LogicalConversationHealth.conflict;
    if (availableSourceCount != certifiedSourceCount) return LogicalConversationHealth.degraded;
    if (partialReadAcknowledgement) return LogicalConversationHealth.partialReadAcknowledgement;
    if (!writeAuthorityReady) return LogicalConversationHealth.readOnly;
    return LogicalConversationHealth.healthy;
  }
}

enum LogicalUnreadObservationResult { advanced, unchanged, staleIgnored }

enum LogicalMarkReadOutcome { nothingToDo, complete, partial }

/// Coalesces overlapping operations for one stable logical identity while
/// allowing different conversations to make progress independently.
class LogicalOperationCoalescer<T> {
  final Map<String, Future<T>> _operations = <String, Future<T>>{};

  int get activeOperationCount => _operations.length;

  Future<T> run(String logicalId, Future<T> Function() operation) {
    final existing = _operations[logicalId];
    if (existing != null) return existing;

    final pending = Future<T>.sync(operation);
    _operations[logicalId] = pending;
    pending.then<void>(
      (_) => _removeIfCurrent(logicalId, pending),
      onError: (Object _, StackTrace _) => _removeIfCurrent(logicalId, pending),
    );
    return pending;
  }

  void _removeIfCurrent(String logicalId, Future<T> operation) {
    if (identical(_operations[logicalId], operation)) {
      _operations.remove(logicalId);
    }
  }
}

/// Runs asynchronous critical sections in FIFO order per stable logical ID.
/// Different logical conversations remain independent. A failed operation is
/// isolated so it cannot poison the key's later work.
class LogicalKeyedSerialExecutor {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  int get activeKeyCount => _tails.length;

  Future<T> run<T>(String logicalId, Future<T> Function() operation) {
    final predecessor = _tails[logicalId] ?? Future<void>.value();
    final result = () async {
      try {
        await predecessor;
      } catch (_) {
        // The prior caller receives its own failure. Later work for this key
        // must still be admitted.
      }
      return operation();
    }();
    final tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _tails[logicalId] = tail;
    tail.whenComplete(() {
      if (identical(_tails[logicalId], tail)) _tails.remove(logicalId);
    });
    return result;
  }
}

class LogicalUnreadObservation {
  LogicalUnreadObservation({
    required this.source,
    required this.revision,
    required this.hasUnread,
    this.eventWatermark = 0,
  }) {
    if (revision < 0) throw ArgumentError.value(revision, 'revision', 'must not be negative');
    if (eventWatermark < 0) {
      throw ArgumentError.value(eventWatermark, 'eventWatermark', 'must not be negative');
    }
  }

  factory LogicalUnreadObservation.fromJson(Map<String, dynamic> json) {
    return LogicalUnreadObservation(
      source: PhysicalConversationRef.fromFingerprint(json['sourceFingerprint'] as String),
      revision: (json['revision'] as num).toInt(),
      hasUnread: json['hasUnread'] as bool,
      eventWatermark: (json['eventWatermark'] as num?)?.toInt() ?? 0,
    );
  }

  final PhysicalConversationRef source;
  final int revision;
  final bool hasUnread;
  final int eventWatermark;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sourceFingerprint': source.fingerprint,
    'revision': revision,
    'hasUnread': hasUnread,
    'eventWatermark': eventWatermark,
  };
}

class LogicalMarkReadPlanEntry {
  const LogicalMarkReadPlanEntry({
    required this.source,
    required this.observedRevision,
    required this.observedEventWatermark,
  });

  final PhysicalConversationRef source;
  final int observedRevision;
  final int observedEventWatermark;
}

class LogicalMarkReadPlan {
  LogicalMarkReadPlan(Iterable<LogicalMarkReadPlanEntry> entries)
    : entries = List<LogicalMarkReadPlanEntry>.unmodifiable(
        entries.toList(growable: false)..sort((left, right) => left.source.compareTo(right.source)),
      );

  final List<LogicalMarkReadPlanEntry> entries;

  bool get isEmpty => entries.isEmpty;
}

class LogicalMarkReadReceipt {
  const LogicalMarkReadReceipt._({
    required this.source,
    required this.plannedRevision,
    required this.succeeded,
    this.resultRevision,
  });

  factory LogicalMarkReadReceipt.success({
    required PhysicalConversationRef source,
    required int plannedRevision,
    required int resultRevision,
  }) {
    if (resultRevision <= plannedRevision) {
      throw ArgumentError('A successful read receipt must advance the provider revision');
    }
    return LogicalMarkReadReceipt._(
      source: source,
      plannedRevision: plannedRevision,
      succeeded: true,
      resultRevision: resultRevision,
    );
  }

  factory LogicalMarkReadReceipt.failure({required PhysicalConversationRef source, required int plannedRevision}) {
    return LogicalMarkReadReceipt._(source: source, plannedRevision: plannedRevision, succeeded: false);
  }

  final PhysicalConversationRef source;
  final int plannedRevision;
  final bool succeeded;
  final int? resultRevision;
}

/// Monotonic read observations scoped to one exact certified source set.
class LogicalUnreadLedger {
  LogicalUnreadLedger({
    required Iterable<PhysicalConversationRef> certifiedSources,
    Iterable<LogicalUnreadObservation> observations = const <LogicalUnreadObservation>[],
  }) : _certifiedSources = <String, PhysicalConversationRef>{},
       _observations = <String, LogicalUnreadObservation>{} {
    for (final source in certifiedSources) {
      if (_certifiedSources.putIfAbsent(source.fingerprint, () => source) != source) {
        throw StateError('LOGICAL_UNREAD_SOURCE_FINGERPRINT_CONFLICT');
      }
    }
    if (_certifiedSources.isEmpty || _certifiedSources.length > LogicalConversationSnapshot.maxMembers) {
      throw ArgumentError('Logical unread source count is outside the supported bound');
    }
    for (final observation in observations) {
      if (!_certifiedSources.containsKey(observation.source.fingerprint)) {
        throw StateError('LOGICAL_UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
      }
      if (_observations.containsKey(observation.source.fingerprint)) {
        throw StateError('LOGICAL_UNREAD_DUPLICATE_SOURCE_OBSERVATION');
      }
      _observations[observation.source.fingerprint] = observation;
    }
  }

  factory LogicalUnreadLedger.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalUnreadLedgerSchema) {
      throw const FormatException('Unsupported logical unread ledger schema');
    }
    final rawSources = json['certifiedSources'];
    final rawObservations = json['observations'];
    if (rawSources is! List || rawObservations is! List) {
      throw const FormatException('Malformed logical unread ledger');
    }
    return LogicalUnreadLedger(
      certifiedSources: rawSources.map((value) => PhysicalConversationRef.fromFingerprint(value as String)),
      observations: rawObservations.map(
        (value) => LogicalUnreadObservation.fromJson((value as Map).cast<String, dynamic>()),
      ),
    );
  }

  final Map<String, PhysicalConversationRef> _certifiedSources;
  final Map<String, LogicalUnreadObservation> _observations;

  List<PhysicalConversationRef> get certifiedSources =>
      List<PhysicalConversationRef>.unmodifiable(_certifiedSources.values.toList(growable: false)..sort());

  List<LogicalUnreadObservation> get observations => List<LogicalUnreadObservation>.unmodifiable(
    _observations.values.toList(growable: false)..sort((left, right) => left.source.compareTo(right.source)),
  );

  bool get hasUnread => _observations.values.any((observation) => observation.hasUnread);

  LogicalUnreadObservation? observationFor(PhysicalConversationRef source) => _observations[source.fingerprint];

  /// Applies one exact physical-source snapshot. Aggregate presentation state
  /// must never be supplied here: every certified source is required exactly
  /// once so unread attribution and later acknowledgements retain provenance.
  bool observePhysicalSnapshot(
    Map<PhysicalConversationRef, bool> physicalUnreadBySource, {
    Map<PhysicalConversationRef, int> eventWatermarks = const <PhysicalConversationRef, int>{},
  }) {
    final supplied = physicalUnreadBySource.keys.map((source) => source.fingerprint).toSet();
    if (supplied.length != physicalUnreadBySource.length ||
        supplied.length != _certifiedSources.length ||
        !supplied.containsAll(_certifiedSources.keys)) {
      throw StateError('LOGICAL_UNREAD_PHYSICAL_SNAPSHOT_INCOMPLETE');
    }
    final suppliedWatermarks = <String, int>{
      for (final entry in eventWatermarks.entries) entry.key.fingerprint: entry.value,
    };
    if (suppliedWatermarks.length != eventWatermarks.length ||
        suppliedWatermarks.keys.any((fingerprint) => !_certifiedSources.containsKey(fingerprint)) ||
        suppliedWatermarks.values.any((watermark) => watermark < 0)) {
      throw StateError('LOGICAL_UNREAD_EVENT_WATERMARK_INVALID');
    }
    var changed = false;
    for (final entry in physicalUnreadBySource.entries) {
      if (!_certifiedSources.containsKey(entry.key.fingerprint)) {
        throw StateError('LOGICAL_UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
      }
      final prior = _observations[entry.key.fingerprint];
      final eventWatermark = suppliedWatermarks[entry.key.fingerprint] ?? prior?.eventWatermark ?? 0;
      if (prior != null && eventWatermark < prior.eventWatermark) continue;
      if (prior == null || prior.hasUnread != entry.value || eventWatermark > prior.eventWatermark) {
        observe(
          LogicalUnreadObservation(
            source: entry.key,
            revision: prior == null ? 0 : prior.revision + 1,
            hasUnread: entry.value,
            eventWatermark: eventWatermark,
          ),
        );
        changed = true;
      }
    }
    return changed;
  }

  /// Applies a uniquely bound subset while retaining every missing member's
  /// last durable observation. This is read projection only; provider mutation
  /// still requires [observePhysicalSnapshot]'s exact certified source set.
  bool observeAvailablePhysicalSnapshot(
    Map<PhysicalConversationRef, bool> physicalUnreadBySource, {
    Map<PhysicalConversationRef, int> eventWatermarks = const <PhysicalConversationRef, int>{},
  }) {
    final supplied = physicalUnreadBySource.keys.map((source) => source.fingerprint).toSet();
    if (supplied.length != physicalUnreadBySource.length ||
        supplied.any((fingerprint) => !_certifiedSources.containsKey(fingerprint))) {
      throw StateError('LOGICAL_UNREAD_PHYSICAL_SUBSET_INVALID');
    }
    final suppliedWatermarks = <String, int>{
      for (final entry in eventWatermarks.entries) entry.key.fingerprint: entry.value,
    };
    if (suppliedWatermarks.length != eventWatermarks.length ||
        suppliedWatermarks.keys.any((fingerprint) => !supplied.contains(fingerprint)) ||
        suppliedWatermarks.values.any((watermark) => watermark < 0)) {
      throw StateError('LOGICAL_UNREAD_EVENT_WATERMARK_INVALID');
    }
    var changed = false;
    for (final entry in physicalUnreadBySource.entries) {
      final prior = _observations[entry.key.fingerprint];
      final eventWatermark = suppliedWatermarks[entry.key.fingerprint] ?? prior?.eventWatermark ?? 0;
      if (prior != null && eventWatermark < prior.eventWatermark) continue;
      if (prior == null || prior.hasUnread != entry.value || eventWatermark > prior.eventWatermark) {
        observe(
          LogicalUnreadObservation(
            source: entry.key,
            revision: prior == null ? 0 : prior.revision + 1,
            hasUnread: entry.value,
            eventWatermark: eventWatermark,
          ),
        );
        changed = true;
      }
    }
    return changed;
  }

  /// Records a newly observed inbound message independently of the Boolean
  /// unread bit. A second message while a source is already unread must still
  /// invalidate any mark-read plan admitted before that message arrived.
  LogicalUnreadObservationResult observeUnreadEvent({
    required PhysicalConversationRef source,
    required int eventWatermark,
  }) {
    if (!_certifiedSources.containsKey(source.fingerprint)) {
      throw StateError('LOGICAL_UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
    }
    if (eventWatermark < 0) {
      throw ArgumentError.value(eventWatermark, 'eventWatermark', 'must not be negative');
    }
    final prior = _observations[source.fingerprint];
    if (prior != null && eventWatermark < prior.eventWatermark) {
      return LogicalUnreadObservationResult.staleIgnored;
    }
    if (prior != null && eventWatermark == prior.eventWatermark) {
      return LogicalUnreadObservationResult.unchanged;
    }
    return observe(
      LogicalUnreadObservation(
        source: source,
        revision: prior == null ? 0 : prior.revision + 1,
        hasUnread: true,
        eventWatermark: eventWatermark,
      ),
    );
  }

  LogicalUnreadObservationResult observe(LogicalUnreadObservation observation) {
    if (!_certifiedSources.containsKey(observation.source.fingerprint)) {
      throw StateError('LOGICAL_UNREAD_SOURCE_OUTSIDE_CERTIFICATE');
    }
    final prior = _observations[observation.source.fingerprint];
    if (prior == null) {
      _observations[observation.source.fingerprint] = observation;
      return LogicalUnreadObservationResult.advanced;
    }
    if (observation.revision < prior.revision) return LogicalUnreadObservationResult.staleIgnored;
    if (observation.revision == prior.revision) {
      if (observation.hasUnread != prior.hasUnread || observation.eventWatermark != prior.eventWatermark) {
        throw StateError('LOGICAL_UNREAD_SAME_REVISION_CONFLICT');
      }
      return LogicalUnreadObservationResult.unchanged;
    }
    if (observation.eventWatermark < prior.eventWatermark) {
      throw StateError('LOGICAL_UNREAD_EVENT_WATERMARK_REGRESSION');
    }
    _observations[observation.source.fingerprint] = observation;
    return LogicalUnreadObservationResult.advanced;
  }

  LogicalMarkReadPlan markReadPlan() => LogicalMarkReadPlan(
    observations
        .where((observation) => observation.hasUnread)
        .map(
          (observation) => LogicalMarkReadPlanEntry(
            source: observation.source,
            observedRevision: observation.revision,
            observedEventWatermark: observation.eventWatermark,
          ),
        ),
  );

  LogicalMarkReadOutcome applyMarkReadReceipts(
    LogicalMarkReadPlan plan,
    Iterable<LogicalMarkReadReceipt> receipts, {
    bool stalePlanAsPartial = false,
  }) {
    if (plan.isEmpty) return LogicalMarkReadOutcome.nothingToDo;
    final currentPlan = markReadPlan();
    final currentMaterial = <String>[
      for (final entry in currentPlan.entries)
        '${entry.source.fingerprint}:${entry.observedRevision}:${entry.observedEventWatermark}',
    ];
    final suppliedMaterial = <String>[
      for (final entry in plan.entries)
        '${entry.source.fingerprint}:${entry.observedRevision}:${entry.observedEventWatermark}',
    ];
    final planIsCurrent = jsonEncode(currentMaterial) == jsonEncode(suppliedMaterial);
    if (!planIsCurrent && !stalePlanAsPartial) {
      throw StateError('LOGICAL_MARK_READ_PLAN_STALE');
    }

    final planBySource = <String, LogicalMarkReadPlanEntry>{
      for (final entry in plan.entries) entry.source.fingerprint: entry,
    };
    final receiptsBySource = <String, LogicalMarkReadReceipt>{};
    for (final receipt in receipts) {
      final entry = planBySource[receipt.source.fingerprint];
      if (entry == null) throw StateError('LOGICAL_MARK_READ_RECEIPT_OUTSIDE_PLAN');
      if (entry.observedRevision != receipt.plannedRevision) {
        throw StateError('LOGICAL_MARK_READ_RECEIPT_REVISION_CONFLICT');
      }
      if (receiptsBySource.containsKey(receipt.source.fingerprint)) {
        throw StateError('LOGICAL_MARK_READ_DUPLICATE_RECEIPT');
      }
      receiptsBySource[receipt.source.fingerprint] = receipt;
    }

    var staleReceiptIgnored = false;
    for (final receipt in receiptsBySource.values.where((receipt) => receipt.succeeded)) {
      final resultRevision = receipt.resultRevision;
      if (resultRevision == null || resultRevision <= receipt.plannedRevision) {
        throw StateError('LOGICAL_MARK_READ_RESULT_REVISION_INVALID');
      }
      final planned = planBySource[receipt.source.fingerprint]!;
      final current = _observations[receipt.source.fingerprint];
      final alreadyConfirmed =
          current != null &&
          !current.hasUnread &&
          current.revision == resultRevision &&
          current.eventWatermark == planned.observedEventWatermark;
      if (alreadyConfirmed) continue;
      if (current == null ||
          !current.hasUnread ||
          current.revision != receipt.plannedRevision ||
          current.eventWatermark != planned.observedEventWatermark) {
        if (!stalePlanAsPartial) throw StateError('LOGICAL_MARK_READ_PLAN_STALE');
        staleReceiptIgnored = true;
        continue;
      }
      _observations[receipt.source.fingerprint] = LogicalUnreadObservation(
        source: receipt.source,
        revision: resultRevision,
        hasUnread: false,
        eventWatermark: current.eventWatermark,
      );
    }
    final allResultsConfirmed = plan.entries.every((entry) {
      final receipt = receiptsBySource[entry.source.fingerprint];
      final current = _observations[entry.source.fingerprint];
      return receipt?.succeeded == true &&
          current != null &&
          !current.hasUnread &&
          current.revision == receipt!.resultRevision &&
          current.eventWatermark == entry.observedEventWatermark;
    });
    return !staleReceiptIgnored &&
            receiptsBySource.length == plan.entries.length &&
            receiptsBySource.values.every((receipt) => receipt.succeeded) &&
            allResultsConfirmed &&
            !hasUnread
        ? LogicalMarkReadOutcome.complete
        : LogicalMarkReadOutcome.partial;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': logicalUnreadLedgerSchema,
    'certifiedSources': certifiedSources.map((source) => source.fingerprint).toList(growable: false),
    'observations': observations.map((observation) => observation.toJson()).toList(growable: false),
  };
}

/// Stable Android notification/shortcut identity for one human conversation.
class LogicalNotificationIdentity {
  const LogicalNotificationIdentity._({required this.stableKey, required this.androidId});

  factory LogicalNotificationIdentity.fromLogicalId(LogicalConversationId logicalId) {
    final stableKey = 'logical-conversation.v1.${_stableFingerprint('notification-key', <String>[logicalId.value])}';
    final digest = sha256.convert(utf8.encode(stableKey)).bytes;
    final unsigned = (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
    final bounded = unsigned & 0x3fffffff;
    final magnitude = 0x40000000 + (bounded == 0 ? 1 : bounded);
    // ObjectBox chat IDs are positive. Logical IDs occupy a disjoint negative
    // namespace; the stable Android tag below also prevents logical hash collisions.
    return LogicalNotificationIdentity._(stableKey: stableKey, androidId: -magnitude);
  }

  static int legacyPositiveAndroidIdForLogicalId(LogicalConversationId logicalId) {
    final stableKey = LogicalNotificationIdentity.fromLogicalId(logicalId).stableKey;
    final digest = sha256.convert(utf8.encode(stableKey)).bytes;
    final unsigned = (digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3];
    final bounded = unsigned & 0x7fffffff;
    return bounded == 0 ? 1 : bounded;
  }

  static int androidIdForConversation({
    required int ordinaryPhysicalChatId,
    LogicalConversationId? certifiedLogicalId,
  }) => certifiedLogicalId == null
      ? ordinaryPhysicalChatId
      : LogicalNotificationIdentity.fromLogicalId(certifiedLogicalId).androidId;

  static String androidTagForConversation({required String ordinaryTag, LogicalConversationId? certifiedLogicalId}) =>
      certifiedLogicalId == null
      ? ordinaryTag
      : '$ordinaryTag.${LogicalNotificationIdentity.fromLogicalId(certifiedLogicalId).stableKey}';

  factory LogicalNotificationIdentity.fromJson(Map<String, dynamic> json, LogicalConversationId logicalId) {
    final expected = LogicalNotificationIdentity.fromLogicalId(logicalId);
    if (json['stableKey'] != expected.stableKey || json['androidId'] != expected.androidId) {
      throw const FormatException('Logical notification identity does not match the logical conversation');
    }
    return expected;
  }

  final String stableKey;
  final int androidId;

  Map<String, dynamic> toJson() => <String, dynamic>{'stableKey': stableKey, 'androidId': androidId};

  @override
  bool operator ==(Object other) =>
      other is LogicalNotificationIdentity && other.stableKey == stableKey && other.androidId == androidId;

  @override
  int get hashCode => Object.hash(stableKey, androidId);
}

class LogicalSearchResult {
  LogicalSearchResult._({
    required this.logicalId,
    required this.source,
    required this.messageFingerprint,
    required this.occurredAtEpochMicroseconds,
  }) {
    _requireFingerprint(messageFingerprint, 'search result message fingerprint');
    if (occurredAtEpochMicroseconds < 0) {
      throw ArgumentError.value(occurredAtEpochMicroseconds, 'occurredAtEpochMicroseconds');
    }
  }

  factory LogicalSearchResult.fromStableMessageId({
    required LogicalConversationId logicalId,
    required PhysicalConversationRef source,
    required String stableMessageId,
    required int occurredAtEpochMicroseconds,
  }) {
    return LogicalSearchResult._(
      logicalId: logicalId,
      source: source,
      messageFingerprint: _stableFingerprint('logical-message-anchor', <String>[
        source.fingerprint,
        _boundedSeed(stableMessageId, 'stableMessageId'),
      ]),
      occurredAtEpochMicroseconds: occurredAtEpochMicroseconds,
    );
  }

  factory LogicalSearchResult.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalSearchResultSchema) {
      throw const FormatException('Unsupported logical search result schema');
    }
    return LogicalSearchResult._(
      logicalId: LogicalConversationId.parse(json['logicalId'] as String),
      source: PhysicalConversationRef.fromFingerprint(json['sourceFingerprint'] as String),
      messageFingerprint: json['messageFingerprint'] as String,
      occurredAtEpochMicroseconds: (json['occurredAtEpochMicroseconds'] as num).toInt(),
    );
  }

  final LogicalConversationId logicalId;
  final PhysicalConversationRef source;
  final String messageFingerprint;
  final int occurredAtEpochMicroseconds;

  ConversationAddress get address => ConversationAddress._(
    logicalId: logicalId,
    compatibility: ConversationAddressCompatibility.logical,
    source: source,
    messageFingerprint: messageFingerprint,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': logicalSearchResultSchema,
    'logicalId': logicalId.value,
    'sourceFingerprint': source.fingerprint,
    'messageFingerprint': messageFingerprint,
    'occurredAtEpochMicroseconds': occurredAtEpochMicroseconds,
  };
}

enum LogicalMediaKind { photo, video, audio, file, link, location, other }

enum LogicalMediaAvailability { available, unavailable, deleted }

class LogicalMediaItem {
  LogicalMediaItem._({
    required this.logicalId,
    required this.source,
    required this.messageFingerprint,
    required this.mediaFingerprint,
    required this.kind,
    required this.availability,
    required this.occurredAtEpochMicroseconds,
  }) {
    _requireFingerprint(messageFingerprint, 'media owning-message fingerprint');
    _requireFingerprint(mediaFingerprint, 'media fingerprint');
    if (occurredAtEpochMicroseconds < 0) {
      throw ArgumentError.value(occurredAtEpochMicroseconds, 'occurredAtEpochMicroseconds');
    }
  }

  factory LogicalMediaItem.fromStableIds({
    required LogicalConversationId logicalId,
    required PhysicalConversationRef source,
    required String stableMessageId,
    required String stableMediaId,
    required LogicalMediaKind kind,
    required LogicalMediaAvailability availability,
    required int occurredAtEpochMicroseconds,
  }) {
    final messageFingerprint = _stableFingerprint('logical-message-anchor', <String>[
      source.fingerprint,
      _boundedSeed(stableMessageId, 'stableMessageId'),
    ]);
    return LogicalMediaItem._(
      logicalId: logicalId,
      source: source,
      messageFingerprint: messageFingerprint,
      mediaFingerprint: _stableFingerprint('logical-media-item', <String>[
        source.fingerprint,
        messageFingerprint,
        _boundedSeed(stableMediaId, 'stableMediaId'),
      ]),
      kind: kind,
      availability: availability,
      occurredAtEpochMicroseconds: occurredAtEpochMicroseconds,
    );
  }

  factory LogicalMediaItem.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalMediaItemSchema) {
      throw const FormatException('Unsupported logical media item schema');
    }
    final kindName = json['kind'] as String;
    final availabilityName = json['availability'] as String;
    final kind = LogicalMediaKind.values.where((candidate) => candidate.name == kindName).firstOrNull;
    final availability = LogicalMediaAvailability.values
        .where((candidate) => candidate.name == availabilityName)
        .firstOrNull;
    if (kind == null || availability == null) throw const FormatException('Unsupported logical media value');
    return LogicalMediaItem._(
      logicalId: LogicalConversationId.parse(json['logicalId'] as String),
      source: PhysicalConversationRef.fromFingerprint(json['sourceFingerprint'] as String),
      messageFingerprint: json['messageFingerprint'] as String,
      mediaFingerprint: json['mediaFingerprint'] as String,
      kind: kind,
      availability: availability,
      occurredAtEpochMicroseconds: (json['occurredAtEpochMicroseconds'] as num).toInt(),
    );
  }

  final LogicalConversationId logicalId;
  final PhysicalConversationRef source;
  final String messageFingerprint;
  final String mediaFingerprint;
  final LogicalMediaKind kind;
  final LogicalMediaAvailability availability;
  final int occurredAtEpochMicroseconds;

  ConversationAddress get owningMessageAddress => ConversationAddress._(
    logicalId: logicalId,
    compatibility: ConversationAddressCompatibility.logical,
    source: source,
    messageFingerprint: messageFingerprint,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': logicalMediaItemSchema,
    'logicalId': logicalId.value,
    'sourceFingerprint': source.fingerprint,
    'messageFingerprint': messageFingerprint,
    'mediaFingerprint': mediaFingerprint,
    'kind': kind.name,
    'availability': availability.name,
    'occurredAtEpochMicroseconds': occurredAtEpochMicroseconds,
  };
}

/// Bounded, reconstructible read-side value object. It contains no message
/// content and grants no write authority.
class LogicalConversationSnapshot {
  static const int maxMembers = 256;
  static const int maxSearchResults = 512;
  static const int maxMediaItems = 512;

  LogicalConversationSnapshot({
    required this.logicalId,
    required Iterable<PhysicalConversationRef> members,
    required this.health,
    required LogicalUnreadLedger unreadLedger,
    required Iterable<LogicalSearchResult> searchResults,
    required Iterable<LogicalMediaItem> mediaItems,
    required this.revision,
  }) : members = List<PhysicalConversationRef>.unmodifiable(members.toSet().toList(growable: false)..sort()),
       notificationIdentity = LogicalNotificationIdentity.fromLogicalId(logicalId),
       _unreadLedger = LogicalUnreadLedger.fromJson(unreadLedger.toJson()),
       searchResults = List<LogicalSearchResult>.unmodifiable(
         searchResults.toList(growable: false)..sort((left, right) {
           final byTime = left.occurredAtEpochMicroseconds.compareTo(right.occurredAtEpochMicroseconds);
           return byTime != 0 ? byTime : left.messageFingerprint.compareTo(right.messageFingerprint);
         }),
       ),
       mediaItems = List<LogicalMediaItem>.unmodifiable(
         mediaItems.toList(growable: false)..sort((left, right) {
           final byTime = left.occurredAtEpochMicroseconds.compareTo(right.occurredAtEpochMicroseconds);
           return byTime != 0 ? byTime : left.mediaFingerprint.compareTo(right.mediaFingerprint);
         }),
       ) {
    _validate();
  }

  factory LogicalConversationSnapshot.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != logicalConversationSnapshotSchema) {
      throw const FormatException('Unsupported logical conversation snapshot schema');
    }
    final logicalId = LogicalConversationId.parse(json['logicalId'] as String);
    final rawMembers = json['members'];
    final rawUnread = json['unreadLedger'];
    final rawSearch = json['searchResults'];
    final rawMedia = json['mediaItems'];
    final rawNotification = json['notificationIdentity'];
    if (rawMembers is! List ||
        rawUnread is! Map ||
        rawSearch is! List ||
        rawMedia is! List ||
        rawNotification is! Map) {
      throw const FormatException('Malformed logical conversation snapshot');
    }
    LogicalNotificationIdentity.fromJson(rawNotification.cast<String, dynamic>(), logicalId);
    final healthName = json['health'] as String;
    final health = LogicalConversationHealth.values.where((candidate) => candidate.name == healthName).firstOrNull;
    if (health == null) throw const FormatException('Unsupported logical conversation health');
    return LogicalConversationSnapshot(
      logicalId: logicalId,
      members: rawMembers.map((value) => PhysicalConversationRef.fromFingerprint(value as String)),
      health: health,
      unreadLedger: LogicalUnreadLedger.fromJson(rawUnread.cast<String, dynamic>()),
      searchResults: rawSearch.map((value) => LogicalSearchResult.fromJson((value as Map).cast<String, dynamic>())),
      mediaItems: rawMedia.map((value) => LogicalMediaItem.fromJson((value as Map).cast<String, dynamic>())),
      revision: (json['revision'] as num).toInt(),
    );
  }

  final LogicalConversationId logicalId;
  final List<PhysicalConversationRef> members;
  final LogicalConversationHealth health;
  final LogicalNotificationIdentity notificationIdentity;
  final LogicalUnreadLedger _unreadLedger;
  final List<LogicalSearchResult> searchResults;
  final List<LogicalMediaItem> mediaItems;
  final int revision;

  LogicalUnreadLedger get unreadLedger => LogicalUnreadLedger.fromJson(_unreadLedger.toJson());

  String get fingerprint => _stableFingerprint('logical-conversation-snapshot', <String>[jsonEncode(toJson())]);

  void _validate() {
    if (members.isEmpty || members.length > maxMembers) {
      throw ArgumentError('Logical conversation member count is outside the supported bound');
    }
    if (revision < 0) throw ArgumentError.value(revision, 'revision', 'must not be negative');
    if (searchResults.length > maxSearchResults || mediaItems.length > maxMediaItems) {
      throw ArgumentError('Logical conversation snapshot collection exceeds its supported bound');
    }
    final memberFingerprints = members.map((member) => member.fingerprint).toSet();
    final ledgerFingerprints = _unreadLedger.certifiedSources.map((member) => member.fingerprint).toSet();
    if (memberFingerprints.length != members.length ||
        memberFingerprints.length != ledgerFingerprints.length ||
        !memberFingerprints.containsAll(ledgerFingerprints)) {
      throw StateError('LOGICAL_SNAPSHOT_MEMBER_LEDGER_CONFLICT');
    }
    for (final result in searchResults) {
      if (result.logicalId != logicalId || !memberFingerprints.contains(result.source.fingerprint)) {
        throw StateError('LOGICAL_SNAPSHOT_SEARCH_PROVENANCE_CONFLICT');
      }
    }
    for (final item in mediaItems) {
      if (item.logicalId != logicalId || !memberFingerprints.contains(item.source.fingerprint)) {
        throw StateError('LOGICAL_SNAPSHOT_MEDIA_PROVENANCE_CONFLICT');
      }
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'schema': logicalConversationSnapshotSchema,
    'logicalId': logicalId.value,
    'members': members.map((member) => member.fingerprint).toList(growable: false),
    'health': health.name,
    'notificationIdentity': notificationIdentity.toJson(),
    'unreadLedger': _unreadLedger.toJson(),
    'searchResults': searchResults.map((result) => result.toJson()).toList(growable: false),
    'mediaItems': mediaItems.map((item) => item.toJson()).toList(growable: false),
    'revision': revision,
  };
}

/// Race-safe unread runtime state for one independently certified human
/// conversation. Provider GUIDs are represented only by physical fingerprints.
class LogicalUnreadConversationState {
  LogicalUnreadConversationState({
    required this.logicalId,
    required this.ledger,
    this.syncPending = false,
    this.lastOutcome,
  }) {
    if (!logicalId.isCertified) {
      throw ArgumentError.value(logicalId, 'logicalId', 'must be certified');
    }
    for (final observation in ledger.observations) {
      _messageWatermarks[observation.source.fingerprint] = observation.eventWatermark;
      if (syncPending && observation.hasUnread) {
        _pendingWatermarks[observation.source.fingerprint] = observation.eventWatermark;
      }
    }
  }

  final LogicalConversationId logicalId;
  final LogicalUnreadLedger ledger;
  bool syncPending;
  LogicalMarkReadOutcome? lastOutcome;
  int _markReadOperationsInFlight = 0;
  final Map<String, int> _messageWatermarks = <String, int>{};
  final Map<String, int> _pendingWatermarks = <String, int>{};
  final Map<String, int> _activeMarkReadWatermarks = <String, int>{};
  final Map<String, int> _providerReadConfirmationCeilings = <String, int>{};

  int get markReadOperationsInFlight => _markReadOperationsInFlight;
  bool get hasPendingWatermarks => _pendingWatermarks.isNotEmpty;

  bool hasExactCertifiedSources(Iterable<PhysicalConversationRef> sources) {
    final expected = ledger.certifiedSources.map((source) => source.fingerprint).toSet();
    final suppliedList = sources.map((source) => source.fingerprint).toList(growable: false);
    final supplied = suppliedList.toSet();
    return supplied.length == suppliedList.length &&
        supplied.length == expected.length &&
        supplied.containsAll(expected);
  }

  int messageWatermarkFor(PhysicalConversationRef source) => _messageWatermarks[source.fingerprint] ?? 0;

  int? pendingWatermarkFor(PhysicalConversationRef source) => _pendingWatermarks[source.fingerprint];

  bool hasPendingWatermark(PhysicalConversationRef source) => _pendingWatermarks.containsKey(source.fingerprint);

  LogicalUnreadObservationResult observeUnreadEvent({required PhysicalConversationRef source, int? observedWatermark}) {
    final priorWatermark = ledger.observationFor(source)?.eventWatermark ?? 0;
    final cachedWatermark = messageWatermarkFor(source);
    final baseline = priorWatermark > cachedWatermark ? priorWatermark : cachedWatermark;
    final candidate = observedWatermark == null || observedWatermark <= 0 ? baseline + 1 : observedWatermark;
    final result = ledger.observeUnreadEvent(source: source, eventWatermark: candidate);
    if (result == LogicalUnreadObservationResult.advanced) {
      _messageWatermarks[source.fingerprint] = candidate;
      if (_markReadOperationsInFlight > 0 || _providerReadConfirmationCeilings.containsKey(source.fingerprint)) {
        retainPending(source, candidate);
        syncPending = true;
      }
    }
    return result;
  }

  /// Records an exact-source provider status notification without issuing a
  /// second provider mutation. The current message watermark is retained so a
  /// status confirmation cannot acknowledge a later inbound event by accident.
  LogicalUnreadObservationResult observeProviderReadStatus({
    required PhysicalConversationRef source,
    required bool hasUnread,
  }) {
    final prior = ledger.observationFor(source);
    final currentWatermark = prior?.eventWatermark ?? messageWatermarkFor(source);
    final admittedReadWatermark =
        _activeMarkReadWatermarks[source.fingerprint] ?? _providerReadConfirmationCeilings[source.fingerprint];
    final pendingWatermark = pendingWatermarkFor(source);
    if (!hasUnread &&
        ((admittedReadWatermark != null && currentWatermark > admittedReadWatermark) ||
            (admittedReadWatermark == null && pendingWatermark != null))) {
      // A provider read-status event has no message watermark. It can confirm
      // the exact plan currently in flight, but it cannot acknowledge a newer
      // inbound event or a durable pending watermark after that plan ended.
      syncPending = true;
      return LogicalUnreadObservationResult.staleIgnored;
    }
    final eventWatermark = admittedReadWatermark ?? currentWatermark;
    if (prior != null && prior.hasUnread == hasUnread) {
      if (!hasUnread) clearPendingThrough(source, eventWatermark);
      return LogicalUnreadObservationResult.unchanged;
    }
    final result = ledger.observe(
      LogicalUnreadObservation(
        source: source,
        revision: prior == null ? 0 : prior.revision + 1,
        hasUnread: hasUnread,
        eventWatermark: eventWatermark,
      ),
    );
    if (result == LogicalUnreadObservationResult.advanced) {
      _messageWatermarks[source.fingerprint] = eventWatermark;
      if (hasUnread) {
        if (_markReadOperationsInFlight > 0) {
          retainPending(source, eventWatermark);
          syncPending = true;
        }
      } else {
        clearPendingThrough(source, eventWatermark);
      }
    }
    return result;
  }

  void retainPending(PhysicalConversationRef source, int watermark) {
    if (!ledger.certifiedSources.contains(source) || watermark < 0) {
      throw StateError('LOGICAL_UNREAD_PENDING_SOURCE_INVALID');
    }
    final current = _pendingWatermarks[source.fingerprint] ?? 0;
    if (watermark >= current) _pendingWatermarks[source.fingerprint] = watermark;
  }

  void clearPendingThrough(PhysicalConversationRef source, int watermark) {
    final pending = pendingWatermarkFor(source);
    if (pending != null && pending <= watermark) {
      _pendingWatermarks.remove(source.fingerprint);
    }
  }

  void beginMarkRead([LogicalMarkReadPlan? plan]) {
    _markReadOperationsInFlight++;
    if (plan == null) return;
    if (_markReadOperationsInFlight != 1 || _activeMarkReadWatermarks.isNotEmpty) {
      throw StateError('LOGICAL_MARK_READ_PLAN_OVERLAP');
    }
    for (final entry in plan.entries) {
      _activeMarkReadWatermarks[entry.source.fingerprint] = entry.observedEventWatermark;
      _providerReadConfirmationCeilings[entry.source.fingerprint] = entry.observedEventWatermark;
    }
  }

  void endMarkRead() {
    if (_markReadOperationsInFlight <= 0) {
      throw StateError('LOGICAL_MARK_READ_IN_FLIGHT_UNDERFLOW');
    }
    _markReadOperationsInFlight--;
    if (_markReadOperationsInFlight == 0) _activeMarkReadWatermarks.clear();
  }
}

/// Disjoint unread state keyed by stable application conversation identity.
class LogicalUnreadConversationStore {
  final Map<LogicalConversationId, LogicalUnreadConversationState> _states =
      <LogicalConversationId, LogicalUnreadConversationState>{};

  LogicalUnreadConversationState? stateFor(LogicalConversationId logicalId) => _states[logicalId];

  void put(LogicalUnreadConversationState state) {
    _states[state.logicalId] = state;
  }

  Iterable<LogicalUnreadConversationState> get states {
    final values = _states.values.toList(growable: false)
      ..sort((left, right) => left.logicalId.compareTo(right.logicalId));
    return List<LogicalUnreadConversationState>.unmodifiable(values);
  }

  bool get anySyncPending => _states.values.any((state) => state.syncPending);
  int get unreadConversationCount => _states.values.where((state) => state.ledger.hasUnread).length;

  void clear() => _states.clear();
}
