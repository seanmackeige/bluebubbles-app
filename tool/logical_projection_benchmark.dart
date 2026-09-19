import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';

const _historySize = 20000;
const _sampleCount = 5;
const _memberRowIds = <int>[2027, 2155, 2156];

class _BenchmarkEvent {
  const _BenchmarkEvent({
    required this.id,
    required this.sourceRowId,
    required this.timestamp,
    required this.eventClass,
    required this.payloadVersion,
    required this.read,
    this.targetId,
  });

  final String id;
  final int sourceRowId;
  final int timestamp;
  final LogicalProjectionEventClass eventClass;
  final int payloadVersion;
  final bool read;
  final String? targetId;

  String get provenance => '$sourceRowId:$id';

  _BenchmarkEvent copyWith({
    LogicalProjectionEventClass? eventClass,
    int? payloadVersion,
    bool? read,
    String? targetId,
  }) {
    return _BenchmarkEvent(
      id: id,
      sourceRowId: sourceRowId,
      timestamp: timestamp,
      eventClass: eventClass ?? this.eventClass,
      payloadVersion: payloadVersion ?? this.payloadVersion,
      read: read ?? this.read,
      targetId: targetId ?? this.targetId,
    );
  }
}

class _OperationCounts {
  int identityReads = 0;
  int provenanceReads = 0;
  int canonicalComparisons = 0;
  int sourceEventsRead = 0;

  void reset() {
    identityReads = 0;
    provenanceReads = 0;
    canonicalComparisons = 0;
    sourceEventsRead = 0;
  }

  Map<String, int> toJson() => <String, int>{
    'source_events_read': sourceEventsRead,
    'identity_reads': identityReads,
    'provenance_reads': provenanceReads,
    'canonical_comparisons': canonicalComparisons,
  };
}

class _ProjectionRun {
  const _ProjectionRun({required this.elapsedMicroseconds, required this.counts, required this.events, this.deltaKind});

  final int elapsedMicroseconds;
  final _OperationCounts counts;
  final List<_BenchmarkEvent> events;
  final LogicalProjectionDeltaKind? deltaKind;
}

class _ProjectionAggregate {
  const _ProjectionAggregate({
    required this.elapsedMicroseconds,
    required this.counts,
    required this.events,
    this.deltaKind,
  });

  final int elapsedMicroseconds;
  final _OperationCounts counts;
  final List<_BenchmarkEvent> events;
  final LogicalProjectionDeltaKind? deltaKind;

  Map<String, Object?> toJson({required int inputEvents, required int inputDeltas, required int fullRebuilds}) {
    return <String, Object?>{
      'elapsed_us': elapsedMicroseconds,
      'samples': _sampleCount,
      'input_events': inputEvents,
      'input_deltas': inputDeltas,
      'output_events': events.length,
      'full_rebuilds': fullRebuilds,
      if (deltaKind != null) 'delta': deltaKind!.name,
      ...counts.toJson(),
    };
  }
}

class _EventCase {
  const _EventCase({required this.name, required this.mutation, required this.event});

  final String name;
  final String mutation;
  final _BenchmarkEvent event;
}

class _PaginationRun {
  const _PaginationRun({required this.elapsedMicroseconds, required this.rowVisits, required this.checksum});

  final int elapsedMicroseconds;
  final int rowVisits;
  final int checksum;
}

void main() {
  final history = _buildHistory();
  _warmUp(history);

  final coldOld = _aggregate(() => _runOldFullRebuild(history));
  final coldIncremental = _aggregate(() => _runIncrementalRebuild(history));
  _requireEquivalent('cold_full_projection', coldOld.events, coldIncremental.events);

  final eventResults = <Map<String, Object?>>[];
  for (final eventCase in _eventCases(history)) {
    final oldInput = _applyToSourceTruth(history, eventCase);
    final oldResult = _aggregate(() => _runOldFullRebuild(oldInput));
    final incrementalResult = _aggregate(() => _runIncrementalUpsert(history, eventCase.event));
    _requireEquivalent(eventCase.name, oldResult.events, incrementalResult.events);
    eventResults.add(<String, Object?>{
      'name': eventCase.name,
      'event_class': eventCase.event.eventClass.name,
      'mutation': eventCase.mutation,
      'equivalent': true,
      'checksum': _checksum(oldResult.events),
      'old_full_rebuild': oldResult.toJson(inputEvents: oldInput.length, inputDeltas: 1, fullRebuilds: 1),
      'incremental': incrementalResult.toJson(inputEvents: history.length, inputDeltas: 1, fullRebuilds: 0),
    });
  }

  final oldPagination = _aggregatePagination(history, deepPrefix: true);
  final incrementalPagination = _aggregatePagination(history, deepPrefix: false);
  if (oldPagination.rowVisits != 378750 || incrementalPagination.rowVisits != 7500) {
    throw StateError('Unexpected pagination counts: ${oldPagination.rowVisits}/${incrementalPagination.rowVisits}');
  }
  if (oldPagination.checksum != incrementalPagination.checksum) {
    throw StateError('Deep-pagination result mismatch: ${oldPagination.checksum}/${incrementalPagination.checksum}');
  }

  final output = <String, Object?>{
    'schema': 'LOGICAL_PROJECTION_BENCHMARK_V1',
    'fixture': <String, Object?>{
      'history_events': history.length,
      'physical_members': _memberRowIds,
      'timing_samples': _sampleCount,
    },
    'cold_full_projection': <String, Object?>{
      'equivalent': true,
      'checksum': _checksum(coldOld.events),
      'old_full_rebuild': coldOld.toJson(inputEvents: history.length, inputDeltas: history.length, fullRebuilds: 1),
      'incremental_rebuild': coldIncremental.toJson(
        inputEvents: history.length,
        inputDeltas: history.length,
        fullRebuilds: 1,
      ),
    },
    'event_cases': eventResults,
    'deep_pagination': <String, Object?>{
      'model': 'source_row_visits',
      'members': 3,
      'pages': 100,
      'page_size': 25,
      'equivalent': true,
      'result_checksum': oldPagination.checksum,
      'old_deep_prefix': <String, Object?>{
        'elapsed_us': oldPagination.elapsedMicroseconds,
        'samples': _sampleCount,
        'operations': oldPagination.rowVisits,
        'checksum': oldPagination.checksum,
      },
      'incremental_cursor': <String, Object?>{
        'elapsed_us': incrementalPagination.elapsedMicroseconds,
        'samples': _sampleCount,
        'operations': incrementalPagination.rowVisits,
        'checksum': incrementalPagination.checksum,
      },
      'amplification': oldPagination.rowVisits / incrementalPagination.rowVisits,
    },
  };

  stdout.writeln(jsonEncode(output));
}

List<_BenchmarkEvent> _buildHistory() {
  const baseTimestamp = 1800000000000;
  return List<_BenchmarkEvent>.generate(_historySize, (index) {
    final sourceRowId = _memberRowIds[index % _memberRowIds.length];
    final eventClass = switch (index) {
      _ when index % 101 == 0 => LogicalProjectionEventClass.attachment,
      _ when index % 67 == 0 => LogicalProjectionEventClass.reply,
      _ when index % 43 == 0 => LogicalProjectionEventClass.reaction,
      _ => LogicalProjectionEventClass.normalMessage,
    };
    return _BenchmarkEvent(
      id: 'event-${index.toString().padLeft(5, '0')}',
      sourceRowId: sourceRowId,
      timestamp: baseTimestamp + (index * 1000),
      eventClass: eventClass,
      payloadVersion: 1,
      read: index < 15000,
      targetId: eventClass == LogicalProjectionEventClass.reaction || eventClass == LogicalProjectionEventClass.reply
          ? 'event-${(index > 0 ? index - 1 : 0).toString().padLeft(5, '0')}'
          : null,
    );
  }, growable: false);
}

List<_EventCase> _eventCases(List<_BenchmarkEvent> history) {
  final nextTimestamp = history.last.timestamp + 1000;
  final attachmentBase = history[19500];
  final readStateBase = history[10000];
  return <_EventCase>[
    _EventCase(
      name: 'normal_append',
      mutation: 'append',
      event: _BenchmarkEvent(
        id: 'event-normal-append',
        sourceRowId: 2156,
        timestamp: nextTimestamp,
        eventClass: LogicalProjectionEventClass.normalMessage,
        payloadVersion: 1,
        read: false,
      ),
    ),
    _EventCase(
      name: 'reaction_append',
      mutation: 'append',
      event: _BenchmarkEvent(
        id: 'event-reaction-append',
        sourceRowId: 2156,
        timestamp: nextTimestamp + 1000,
        eventClass: LogicalProjectionEventClass.reaction,
        payloadVersion: 1,
        read: false,
        targetId: history[17777].id,
      ),
    ),
    _EventCase(
      name: 'reply_append',
      mutation: 'append',
      event: _BenchmarkEvent(
        id: 'event-reply-append',
        sourceRowId: 2156,
        timestamp: nextTimestamp + 2000,
        eventClass: LogicalProjectionEventClass.reply,
        payloadVersion: 1,
        read: false,
        targetId: history[8888].id,
      ),
    ),
    _EventCase(
      name: 'attachment_update',
      mutation: 'update',
      event: attachmentBase.copyWith(
        eventClass: LogicalProjectionEventClass.attachment,
        payloadVersion: attachmentBase.payloadVersion + 1,
      ),
    ),
    _EventCase(
      name: 'read_state_update',
      mutation: 'update',
      event: readStateBase.copyWith(
        eventClass: LogicalProjectionEventClass.readState,
        payloadVersion: readStateBase.payloadVersion + 1,
        read: !readStateBase.read,
      ),
    ),
  ];
}

List<_BenchmarkEvent> _applyToSourceTruth(List<_BenchmarkEvent> history, _EventCase eventCase) {
  final updated = history.toList(growable: eventCase.mutation == 'append');
  if (eventCase.mutation == 'append') {
    updated.add(eventCase.event);
    return updated;
  }
  final index = updated.indexWhere((event) => event.id == eventCase.event.id);
  if (index < 0) throw StateError('Update target missing: ${eventCase.event.id}');
  updated[index] = eventCase.event;
  return updated;
}

_ProjectionRun _runOldFullRebuild(List<_BenchmarkEvent> sourceTruth) {
  final counts = _OperationCounts();
  final stopwatch = Stopwatch()..start();
  final byId = <String, _BenchmarkEvent>{};
  for (final event in sourceTruth) {
    counts.sourceEventsRead++;
    counts.identityReads++;
    final existing = byId[event.id];
    if (existing != null) {
      counts.provenanceReads += 2;
      if (existing.provenance != event.provenance) {
        throw StateError('LOGICAL_EVENT_PROVENANCE_CONFLICT:${event.id}');
      }
    }
    byId[event.id] = event;
  }
  final ordered = byId.values.toList(growable: false);
  ordered.sort((left, right) {
    counts.canonicalComparisons++;
    final byValue = _compareEvents(left, right);
    if (byValue != 0) return byValue;
    counts.identityReads += 2;
    return left.id.compareTo(right.id);
  });
  stopwatch.stop();
  return _ProjectionRun(elapsedMicroseconds: stopwatch.elapsedMicroseconds, counts: counts, events: ordered);
}

_ProjectionRun _runIncrementalRebuild(List<_BenchmarkEvent> sourceTruth) {
  final counts = _OperationCounts();
  final projection = _newProjection(counts);
  final stopwatch = Stopwatch()..start();
  projection.rebuild(sourceTruth);
  stopwatch.stop();
  counts.sourceEventsRead = sourceTruth.length;
  return _ProjectionRun(elapsedMicroseconds: stopwatch.elapsedMicroseconds, counts: counts, events: projection.values);
}

_ProjectionRun _runIncrementalUpsert(List<_BenchmarkEvent> history, _BenchmarkEvent event) {
  final counts = _OperationCounts();
  final projection = _newProjection(counts);
  projection.rebuild(history);
  counts.reset();
  final stopwatch = Stopwatch()..start();
  final delta = projection.upsert(event, eventClass: event.eventClass);
  stopwatch.stop();
  counts.sourceEventsRead = 1;
  return _ProjectionRun(
    elapsedMicroseconds: stopwatch.elapsedMicroseconds,
    counts: counts,
    events: projection.values,
    deltaKind: delta.kind,
  );
}

IncrementalLogicalProjection<_BenchmarkEvent> _newProjection(_OperationCounts counts) {
  return IncrementalLogicalProjection<_BenchmarkEvent>(
    identityOf: (event) {
      counts.identityReads++;
      return event.id;
    },
    provenanceOf: (event) {
      counts.provenanceReads++;
      return event.provenance;
    },
    compare: (left, right) {
      counts.canonicalComparisons++;
      return _compareEvents(left, right);
    },
    equivalent: _sameEvent,
  );
}

int _compareEvents(_BenchmarkEvent left, _BenchmarkEvent right) {
  final byTimestamp = left.timestamp.compareTo(right.timestamp);
  if (byTimestamp != 0) return byTimestamp;
  return left.sourceRowId.compareTo(right.sourceRowId);
}

bool _sameEvent(_BenchmarkEvent left, _BenchmarkEvent right) {
  return left.id == right.id &&
      left.sourceRowId == right.sourceRowId &&
      left.timestamp == right.timestamp &&
      left.eventClass == right.eventClass &&
      left.payloadVersion == right.payloadVersion &&
      left.read == right.read &&
      left.targetId == right.targetId;
}

_ProjectionAggregate _aggregate(_ProjectionRun Function() run) {
  final runs = List<_ProjectionRun>.generate(_sampleCount, (_) => run(), growable: false);
  final expectedChecksum = _checksum(runs.first.events);
  for (final sample in runs.skip(1)) {
    if (_checksum(sample.events) != expectedChecksum || sample.events.length != runs.first.events.length) {
      throw StateError('Non-deterministic benchmark result');
    }
  }
  final elapsed = runs.map((sample) => sample.elapsedMicroseconds).toList()..sort();
  return _ProjectionAggregate(
    elapsedMicroseconds: elapsed[elapsed.length ~/ 2],
    counts: runs.first.counts,
    events: runs.first.events,
    deltaKind: runs.first.deltaKind,
  );
}

void _requireEquivalent(String name, List<_BenchmarkEvent> left, List<_BenchmarkEvent> right) {
  if (left.length != right.length) {
    throw StateError('$name length mismatch: ${left.length}/${right.length}');
  }
  for (var index = 0; index < left.length; index++) {
    if (!_sameEvent(left[index], right[index])) {
      throw StateError('$name mismatch at index $index: ${left[index].id}/${right[index].id}');
    }
  }
}

int _checksum(List<_BenchmarkEvent> events) {
  var value = 17;
  for (final event in events) {
    value = _mix(value, event.id);
    value = ((value * 31) ^ event.sourceRowId ^ event.timestamp ^ event.payloadVersion) & 0x7fffffff;
    value = ((value * 31) ^ event.eventClass.index ^ (event.read ? 1 : 0)) & 0x7fffffff;
    if (event.targetId != null) value = _mix(value, event.targetId!);
  }
  return value;
}

int _mix(int seed, String text) {
  var value = seed;
  for (final unit in text.codeUnits) {
    value = ((value * 31) ^ unit) & 0x7fffffff;
  }
  return value;
}

_PaginationRun _aggregatePagination(List<_BenchmarkEvent> history, {required bool deepPrefix}) {
  final runs = List<_PaginationRun>.generate(
    _sampleCount,
    (_) => _runPagination(history, deepPrefix: deepPrefix),
    growable: false,
  );
  final elapsed = runs.map((sample) => sample.elapsedMicroseconds).toList()..sort();
  final expectedVisits = runs.first.rowVisits;
  for (final sample in runs.skip(1)) {
    if (sample.rowVisits != expectedVisits || sample.checksum != runs.first.checksum) {
      throw StateError('Non-deterministic pagination result');
    }
  }
  return _PaginationRun(
    elapsedMicroseconds: elapsed[elapsed.length ~/ 2],
    rowVisits: expectedVisits,
    checksum: runs.first.checksum,
  );
}

_PaginationRun _runPagination(List<_BenchmarkEvent> history, {required bool deepPrefix}) {
  var rowVisits = 0;
  final fetched = <String, _BenchmarkEvent>{};
  final sources = <int, List<_BenchmarkEvent>>{
    for (final rowId in _memberRowIds)
      rowId: history.where((event) => event.sourceRowId == rowId).toList(growable: false),
  };
  final stopwatch = Stopwatch()..start();
  for (var page = 0; page < 100; page++) {
    for (var member = 0; member < _memberRowIds.length; member++) {
      final start = deepPrefix ? 0 : page * 25;
      final end = deepPrefix ? (page + 1) * 25 : start + 25;
      for (var row = start; row < end; row++) {
        final event = sources[_memberRowIds[member]]![row];
        fetched[event.provenance] = event;
        rowVisits++;
      }
    }
  }
  final canonical = fetched.values.toList(growable: false)..sort(_compareEvents);
  final checksum = _checksum(canonical);
  stopwatch.stop();
  return _PaginationRun(elapsedMicroseconds: stopwatch.elapsedMicroseconds, rowVisits: rowVisits, checksum: checksum);
}

void _warmUp(List<_BenchmarkEvent> history) {
  final subset = history.take(512).toList(growable: false);
  _runOldFullRebuild(subset);
  _runIncrementalRebuild(subset);
  _runIncrementalUpsert(
    subset,
    _BenchmarkEvent(
      id: 'warm-up-event',
      sourceRowId: 2156,
      timestamp: subset.last.timestamp + 1000,
      eventClass: LogicalProjectionEventClass.normalMessage,
      payloadVersion: 1,
      read: false,
    ),
  );
}
