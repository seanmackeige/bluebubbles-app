import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:crypto/crypto.dart';

const logicalConversationCertificateLedgerSchema = 'LOGICAL_CONVERSATION_CERTIFICATE_LEDGER_V2';

const _stableRuntimeCertificateSchema = 'LOGICAL_CONVERSATION_RUNTIME_CERTIFICATE_V2_GUID_BINDING';

dynamic _canonicalJson(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList(growable: false)..sort();
    return <String, dynamic>{for (final key in keys) key: _canonicalJson(value[key])};
  }
  if (value is List) return value.map(_canonicalJson).toList(growable: false);
  return value;
}

Map<String, dynamic> _copyMap(Map<dynamic, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

String _certificateStableId(Map<String, dynamic> envelope) {
  if (envelope['schema'] != _stableRuntimeCertificateSchema || envelope['certificate'] is! Map) {
    throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_CERTIFICATE_ENVELOPE_INVALID');
  }
  final payload = (envelope['certificate'] as Map).cast<String, dynamic>();
  final id = payload['id'];
  if (id is! String || id.isEmpty) {
    throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_CERTIFICATE_ID_INVALID');
  }
  void rejectLocalCoordinates(dynamic value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key.toString().toLowerCase().contains('rowid')) {
          throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_LOCAL_COORDINATE_FORBIDDEN');
        }
        rejectLocalCoordinates(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        rejectLocalCoordinates(item);
      }
    }
  }

  rejectLocalCoordinates(envelope);
  return id;
}

/// One privacy-safe authority record. Both envelopes contain only provider
/// fingerprints and evidence receipts; runtime ROWIDs and raw GUIDs are
/// rejected by the codec.
class LogicalConversationCertificateLedgerRecord {
  LogicalConversationCertificateLedgerRecord({
    required this.logicalId,
    required Map<String, dynamic> trustedAnchorEnvelope,
    required Map<String, dynamic> certificateEnvelope,
  }) : trustedAnchorEnvelope = _copyMap(trustedAnchorEnvelope),
       certificateEnvelope = _copyMap(certificateEnvelope) {
    if (!logicalId.isCertified) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_LOGICAL_ID_INVALID');
    }
    final trustedId = _certificateStableId(this.trustedAnchorEnvelope);
    final certificateId = _certificateStableId(this.certificateEnvelope);
    if (trustedId != certificateId || LogicalConversationId.certified(trustedId) != logicalId) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_IDENTITY_MISMATCH');
    }
  }

  final LogicalConversationId logicalId;
  final Map<String, dynamic> trustedAnchorEnvelope;
  final Map<String, dynamic> certificateEnvelope;

  LogicalConversationCertificateLedgerRecord withCertificateEnvelope(Map<String, dynamic> envelope) =>
      LogicalConversationCertificateLedgerRecord(
        logicalId: logicalId,
        trustedAnchorEnvelope: trustedAnchorEnvelope,
        certificateEnvelope: envelope,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'trusted_anchor': trustedAnchorEnvelope,
    'certificate': certificateEnvelope,
  };

  factory LogicalConversationCertificateLedgerRecord.fromJson(String logicalId, Map<String, dynamic> json) {
    final trusted = json['trusted_anchor'];
    final certificate = json['certificate'];
    if (trusted is! Map || certificate is! Map) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_RECORD_INVALID');
    }
    return LogicalConversationCertificateLedgerRecord(
      logicalId: LogicalConversationId.parse(logicalId),
      trustedAnchorEnvelope: trusted.cast<String, dynamic>(),
      certificateEnvelope: certificate.cast<String, dynamic>(),
    );
  }
}

/// Versioned, single-value durable authority ledger. A single JSON write
/// replaces the full ledger, so migration and entry advancement cannot expose
/// a partially rewritten entry set.
class LogicalConversationCertificateLedger {
  LogicalConversationCertificateLedger(Iterable<LogicalConversationCertificateLedgerRecord> records)
    : records = List<LogicalConversationCertificateLedgerRecord>.unmodifiable(
        records.toList(growable: false)..sort((left, right) => left.logicalId.compareTo(right.logicalId)),
      ) {
    if (this.records.isEmpty) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_EMPTY');
    }
    final ids = this.records.map((record) => record.logicalId).toSet();
    if (ids.length != this.records.length) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_DUPLICATE_LOGICAL_ID');
    }
  }

  final List<LogicalConversationCertificateLedgerRecord> records;

  LogicalConversationCertificateLedgerRecord? recordFor(LogicalConversationId logicalId) {
    for (final record in records) {
      if (record.logicalId == logicalId) return record;
    }
    return null;
  }

  LogicalConversationCertificateLedger replaceCertificateEnvelope(Map<String, dynamic> envelope) {
    final stableId = _certificateStableId(envelope);
    final logicalId = LogicalConversationId.certified(stableId);
    if (recordFor(logicalId) == null) {
      throw StateError('LOGICAL_CERTIFICATE_LEDGER_UNTRUSTED_ENTRY');
    }
    return LogicalConversationCertificateLedger(<LogicalConversationCertificateLedgerRecord>[
      for (final record in records)
        if (record.logicalId == logicalId) record.withCertificateEnvelope(envelope) else record,
    ]);
  }

  Map<String, dynamic> _unsignedJson() => <String, dynamic>{
    'schema': logicalConversationCertificateLedgerSchema,
    'entries': <String, dynamic>{for (final record in records) record.logicalId.value: record.toJson()},
  };

  String get revision => sha256.convert(utf8.encode(jsonEncode(_canonicalJson(_unsignedJson())))).toString();

  Map<String, dynamic> toJson() => <String, dynamic>{..._unsignedJson(), 'revision': revision};

  String encode() => jsonEncode(_canonicalJson(toJson()));

  factory LogicalConversationCertificateLedger.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_ENVELOPE_INVALID');
    final json = decoded.cast<String, dynamic>();
    final entries = json['entries'];
    if (json['schema'] != logicalConversationCertificateLedgerSchema || entries is! Map) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_ENVELOPE_INVALID');
    }
    final records = <LogicalConversationCertificateLedgerRecord>[];
    for (final entry in entries.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_RECORD_INVALID');
      }
      records.add(
        LogicalConversationCertificateLedgerRecord.fromJson(
          entry.key as String,
          (entry.value as Map).cast<String, dynamic>(),
        ),
      );
    }
    final ledger = LogicalConversationCertificateLedger(records);
    if (json['revision'] != ledger.revision) {
      throw const FormatException('LOGICAL_CERTIFICATE_LEDGER_REVISION_INVALID');
    }
    return ledger;
  }
}
