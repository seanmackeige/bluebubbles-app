import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_storage.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_confirmation_transaction.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_diagnostics.dart';
import 'independent_model_fixture.dart' as m;

final results = <String, Object?>{};
final failures = <String>[];
Future<void> check(String name, FutureOr<void> Function() body) async {
  try { await body(); results[name] = 'PASS'; }
  catch (error) { failures.add(name); results[name] = 'FAIL: $error'; }
}
void require(bool condition, String detail) { if (!condition) throw StateError(detail); }
class PrivateError {
  @override String toString() => throw StateError('PRIVATE_TO_STRING_MUST_NOT_RUN');
}

Future<void> main() async {
  for (final scenario in ['canonical success', 'legacy slot success', 'missing', 'equal dual', 'conflicting dual',
    'newer action', 'changed text', 'timestamp changed', 'context stale initially', 'write fails before effect',
    'write fails after effect', 'context changes during write', 'newer draft after write', 'slot changes after write']) {
    await check('transaction $scenario', () async {
      final storage = LogicalDraftStorage('sanitized-certified-owner');
      final expected = m.legacy(logicalId: storage.canonicalKey);
      final key = scenario == 'legacy slot success' ? storage.legacyKey : storage.canonicalKey;
      final rows = <String, String>{key: jsonEncode(expected.toJson())};
      var context = scenario != 'context stale initially';
      var writes = 0;
      final newer = m.legacy(logicalId: storage.canonicalKey, text: 'NEWER_SANITIZED_INTENT', created: 99);
      if (scenario == 'missing') rows.clear();
      if (scenario == 'equal dual') rows[storage.legacyKey] = rows[key]!;
      if (scenario == 'conflicting dual') rows[storage.legacyKey] = jsonEncode(newer.toJson());
      if (scenario == 'newer action') rows[key] = jsonEncode(m.legacy(logicalId: storage.canonicalKey, created: 99).toJson());
      if (scenario == 'changed text') rows[key] = jsonEncode(newer.toJson());
      if (scenario == 'timestamp changed') {
        final changed = expected.toJson()..['updatedAtEpochMilliseconds'] = 99;
        rows[key] = jsonEncode(changed);
      }
      final before = jsonEncode(rows);
      LogicalDraft? returned;
      Object? error;
      try {
        returned = await confirmLogicalDraftAtomically(expected: expected, proof: m.proof(expected),
          read: () => storage.read((key) => rows[key]),
          write: (key, value) async {
            writes++;
            if (scenario == 'write fails before effect' && writes == 1) throw StateError('WRITE_REJECTED');
            rows[key] = value;
            if (writes == 1) {
              if (scenario == 'write fails after effect') throw StateError('UNCERTAIN_WRITE');
              if (scenario == 'context changes during write') context = false;
              if (scenario == 'newer draft after write') rows[key] = jsonEncode(newer.toJson());
              if (scenario == 'slot changes after write') { rows.remove(key); rows[storage.legacyKey] = value; }
            }
          }, contextIsCurrent: () => context, nowEpochMilliseconds: 100);
      } catch (caught) { error = caught; }
      final success = scenario.endsWith('success');
      require((returned != null) == success && (error == null) == success, 'Unexpected transaction result');
      if (success) {
        require(writes == 1 && rows.length == 1 && rows.containsKey(key), 'Not one unchanged occupied slot');
        require(returned!.actionId == expected.actionId && returned.contentFingerprint == expected.contentFingerprint, 'Intent changed');
        require(LogicalDraft.fromJson(jsonDecode(rows[key]!)).metadataClass == LogicalDraftMetadataClass.modernBoundDraft, 'Success not durable');
      } else if (['missing', 'equal dual', 'conflicting dual', 'newer action', 'changed text', 'timestamp changed', 'context stale initially'].contains(scenario)) {
        require(writes == 0 && jsonEncode(rows) == before, 'Precondition failure mutated custody');
      } else if (scenario == 'newer draft after write') {
        require(rows[key] == jsonEncode(newer.toJson()), 'Failure overwrote newer intent');
      } else if (['write fails after effect', 'context changes during write'].contains(scenario)) {
        final retained = LogicalDraft.fromJson(jsonDecode(rows[key]!));
        require(retained.actionId == expected.actionId && retained.contentFingerprint == expected.contentFingerprint, 'Failure lost intent');
        require(retained.metadataClass != LogicalDraftMetadataClass.modernBoundDraft,
          'Failed confirmation left a durable ready record');
      }
    });
  }
  await check('serialized duplicate confirmations create one metadata upgrade', () async {
    final storage = LogicalDraftStorage('serialized-owner');
    final expected = m.legacy(logicalId: storage.canonicalKey);
    final rows = <String, String>{storage.canonicalKey: jsonEncode(expected.toJson())};
    final queue = LogicalDraftSaveTransactionQueue();
    var writes = 0;
    Future<bool> operation() async {
      try {
        await queue.run(() => confirmLogicalDraftAtomically(expected: expected, proof: m.proof(expected),
          read: () => storage.read((key) => rows[key]), write: (key, value) async { writes++; rows[key] = value; },
          contextIsCurrent: () => true, nowEpochMilliseconds: 100));
        return true;
      } catch (_) { return false; }
    }
    final outcomes = await Future.wait([operation(), operation()]);
    require(outcomes.where((ok) => ok).length == 1 && writes == 1, 'Duplicate confirmation upgraded more than once');
  });
  for (final scenario in ['small', 'unicode', 'large bounded', 'oversized']) {
    await check('diagnostic frame $scenario', () {
      final record = <String, Object?>{'schema': 'SANITIZED_DIAGNOSTIC_V1', 'result': 'PASS',
        'value': scenario == 'unicode' ? List.filled(300, '🧪').join() :
          scenario == 'large bounded' ? List.filled(12000, 'x').join() :
          scenario == 'oversized' ? List.filled(40000, 'x').join() : 'short'};
      if (scenario == 'oversized') {
        var rejected = false; try { logicalDraftDiagnosticFrames(record).toList(); } catch (_) { rejected = true; }
        require(rejected, 'Oversized diagnostic unbounded'); return;
      }
      final frames = logicalDraftDiagnosticFrames(record).toList();
      final decoded = frames.map((line) => (jsonDecode(line) as Map).cast<String, dynamic>()).toList();
      require(frames.every((line) => utf8.encode(line).length < 900), 'Frame can hit Android truncation');
      require(decoded.map((frame) => frame['capture']).toSet().length == 1, 'Capture mixed');
      require(decoded.every((frame) => frame['count'] == frames.length), 'Count mismatch');
      final payload = <int>[];
      for (var i = 0; i < decoded.length; i++) {
        require(decoded[i]['part'] == i, 'Noncontiguous index');
        payload.addAll(base64Decode(decoded[i]['payload']));
      }
      final hash = sha256.convert(payload).toString();
      require(decoded.every((frame) => frame['sha256'] == hash), 'Checksum mismatch');
      require(jsonEncode(jsonDecode(utf8.decode(payload))) == jsonEncode(record), 'UTF8 reassembly changed record');
      if (frames.length > 1) {
        require(decoded.take(decoded.length - 1).length != decoded.first['count'], 'Missing tail could be complete');
      }
    });
  }
  await check('separate diagnostic captures do not collide', () {
    final captures = <String>{};
    for (var i = 0; i < 100; i++) {
      final line = logicalDraftDiagnosticFrames({'schema': 'S', 'value': i}).first;
      captures.add(jsonDecode(line)['capture']);
    }
    require(captures.length == 100, 'Independent frames share capture id');
  });
  for (final scenario in ['fixed reason', 'private path', 'known prefix with private suffix', 'format exception',
    'ordinary exception', 'throwing error string', 'missing snapshot', 'invalidated snapshot']) {
    await check('confirmation failure diagnostics $scenario', () {
      final original = m.legacy(text: 'PRIVATE_MESSAGE_SENTINEL');
      final draft = scenario == 'missing snapshot' ? null : scenario == 'invalidated snapshot'
          ? m.edit(m.confirmed(original), text: 'PRIVATE_NEW_MESSAGE_SENTINEL') : original;
      final Object error = switch (scenario) {
        'private path' => StateError('/private/PRIVATE_PATH_SENTINEL'),
        'known prefix with private suffix' => StateError('CONFIRMATION_NOT_ELIGIBLE /private/PRIVATE_PATH_SENTINEL'),
        'format exception' => const FormatException('PRIVATE_MESSAGE_SENTINEL'),
        'ordinary exception' => Exception('PRIVATE_MESSAGE_SENTINEL'),
        'throwing error string' => PrivateError(),
        _ => StateError('CONFIRMATION_NOT_ELIGIBLE'),
      };
      final before = draft == null ? null : jsonEncode(draft.toJson());
      final record = logicalDraftConfirmationFailureRecord(draft: draft,
          authorityAtReview: scenario == 'missing snapshot' ? null : m.current, error: error);
      final expectedReason = ['fixed reason', 'missing snapshot', 'invalidated snapshot'].contains(scenario)
          ? 'CONFIRMATION_NOT_ELIGIBLE' : 'CONFIRMATION_STORAGE_OR_CONTEXT_FAILURE';
      require(record['reason'] == expectedReason && record['confirmationResult'] == 'PAUSED' &&
          record['sendAdmissionResult'] == 'NOT_ENTERED' && record['physicalDispatchCount'] == 0,
          'Failure result/allowlist incorrect');
      require(record['confirmationRevision'] == (scenario == 'invalidated snapshot' ? 2 : 1), 'Wrong attempted revision');
      require(!jsonEncode(record).contains('PRIVATE_'), 'Private error or draft content leaked');
      final frames = logicalDraftDiagnosticFrames(record).toList();
      final rebuilt = <int>[];
      for (final line in frames) {
        require(utf8.encode(line).length < 900, 'Failure frame too long');
        rebuilt.addAll(base64Decode(jsonDecode(line)['payload']));
      }
      require(jsonEncode(jsonDecode(utf8.decode(rebuilt))) == jsonEncode(record), 'Failure framing lost fields');
      require((draft == null ? null : jsonEncode(draft.toJson())) == before, 'Diagnostic changed draft');
    });
  }
  print(jsonEncode({'scope': 'Actual pure transaction and frame generator; fake single-value preferences only; no provider, queue dispatch, ledger or transport',
    'caseCount': results.length, 'failures': failures, 'results': results}));
  if (failures.isNotEmpty) exitCode = 1;
}
