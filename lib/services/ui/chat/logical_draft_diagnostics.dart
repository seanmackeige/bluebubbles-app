import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'logical_draft.dart';

/// Only fixed reasons may cross the diagnostic boundary. Storage/plugin
/// exceptions can contain private paths and must never be interpolated.
Map<String, Object?> logicalDraftConfirmationFailureRecord({
  required LogicalDraft? draft,
  required LogicalAuthorityRevision? authorityAtReview,
  required Object error,
}) {
  const reasons = <String>{
    'CONFIRMATION_NOT_ELIGIBLE',
    'CONFIRMATION_VISIBLE_DRAFT_CHANGED',
    'CONFIRMATION_ALREADY_IN_PROGRESS',
    'CONFIRMATION_CUSTODY_UNAVAILABLE',
    'CONFIRMATION_CURRENT_AUTHORITY_UNAVAILABLE',
    'CONFIRMATION_CURRENT_PROOF_UNAVAILABLE',
    'CONFIRMATION_DRAFT_OR_CONTEXT_CHANGED',
    'CONFIRMATION_NOT_READY_AFTER_PERSISTENCE',
    'LOGICAL_DRAFT_CONFIRMATION_CAS_REJECTED',
    'LOGICAL_DRAFT_STORAGE_UNREADABLE',
    'LOGICAL_DRAFT_STORAGE_CONFLICT',
  };
  final reason = error is StateError && reasons.contains(error.message)
      ? error.message
      : 'CONFIRMATION_STORAGE_OR_CONTEXT_FAILURE';
  return <String, Object?>{
    'schema': 'LOGICAL_DRAFT_CONFIRMATION_RESULT_V1',
    'snapshotScope': 'LAST_CAPTURED_STORED_DRAFT_AND_HUMAN_REVIEW_ANCHOR',
    'draftClass': draft?.metadataClass.diagnosticName,
    'contentFingerprint': draft?.contentFingerprint,
    'logicalFingerprint': draft?.logicalFingerprint,
    'confirmationRevision': (draft?.confirmation?.revision ?? 0) + 1,
    'certificateRevision': authorityAtReview?.certificateRevision,
    'authorityRevision': authorityAtReview?.authorityRevision,
    'epoch': authorityAtReview?.epoch,
    'confirmationResult': 'PAUSED',
    'reason': reason,
    'sendAdmissionResult': 'NOT_ENTERED',
    'physicalDispatchCount': 0,
  };
}

/// Each Android log line is independently valid JSON and below 900 UTF-8
/// bytes. Reassembly requires every indexed frame and the complete checksum.
Iterable<String> logicalDraftDiagnosticFrames(Map<String, Object?> record) sync* {
  final bytes = utf8.encode(jsonEncode(record));
  if (bytes.length > 32768) throw StateError('DRAFT_DIAGNOSTIC_BOUND_EXCEEDED');
  final checksum = sha256.convert(bytes).toString();
  final capture = '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
  final count = (bytes.length + 359) ~/ 360;
  for (var index = 0; index < count; index++) {
    final frame = jsonEncode(<String, Object?>{
      'schema': 'LOGICAL_DRAFT_DIAGNOSTIC_FRAME_V1',
      'recordSchema': record['schema'],
      'capture': capture,
      'part': index,
      'count': count,
      'sha256': checksum,
      'payload': base64Encode(bytes.sublist(index * 360, min(bytes.length, (index + 1) * 360))),
    });
    if (utf8.encode(frame).length >= 900) throw StateError('DRAFT_DIAGNOSTIC_FRAME_TOO_LARGE');
    yield frame;
  }
}
