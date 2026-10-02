import 'dart:async';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';

enum LogicalCertificateAdvancementDisposition { committed, staleRevision, activationRejected }

class LogicalCertificateAuthorityState {
  const LogicalCertificateAuthorityState({required this.ledgerJson, required this.legacyCertificateJson});

  final String? ledgerJson;
  final String? legacyCertificateJson;
}

class LogicalCertificateAdvancementResult {
  const LogicalCertificateAdvancementResult({required this.disposition, required this.logicalId, this.ledgerJson});

  final LogicalCertificateAdvancementDisposition disposition;
  final LogicalConversationId logicalId;
  final String? ledgerJson;

  bool get committed => disposition == LogicalCertificateAdvancementDisposition.committed;
}

typedef LoadLogicalCertificateAuthority = Future<LogicalCertificateAuthorityState> Function();
typedef PersistLogicalCertificateAuthority =
    Future<void> Function(String ledgerJson, String? bankedLegacyCertificateJson);
typedef ActivateLogicalCertificateAuthority = Future<bool> Function(String ledgerJson);

/// Serializes every durable certificate advancement in this process. The
/// fresh load, exact target-revision check, merge, single-ledger write, and
/// runtime activation are one critical section, so concurrent authorities
/// cannot overwrite each other and a stale same-authority writer fails closed.
class LogicalCertificateAdvancementTransactionQueue {
  Completer<void>? _mutex;

  Future<LogicalCertificateAdvancementResult> commit({
    required String runtimeCertificateJson,
    required String expectedPersistedCertificateRevision,
    required LoadLogicalCertificateAuthority loadAuthority,
    required PersistLogicalCertificateAuthority persistAuthority,
    required ActivateLogicalCertificateAuthority activateAuthority,
  }) async {
    while (_mutex != null) {
      await _mutex!.future;
    }
    final mutex = Completer<void>();
    _mutex = mutex;
    try {
      final logicalId = LogicalConversationViewPolicy.logicalIdForRuntimeCertificate(runtimeCertificateJson);
      final authority = await loadAuthority();
      final currentRevision = LogicalConversationViewPolicy.certificateRevisionForPersistedAuthority(
        persistedLedgerJson: authority.ledgerJson,
        legacyCertificateJson: authority.legacyCertificateJson,
        logicalId: logicalId,
      );
      if (currentRevision != expectedPersistedCertificateRevision) {
        return LogicalCertificateAdvancementResult(
          disposition: LogicalCertificateAdvancementDisposition.staleRevision,
          logicalId: logicalId,
        );
      }

      final merged = LogicalConversationViewPolicy.mergeRuntimeCertificateIntoLedger(
        persistedLedgerJson: authority.ledgerJson,
        runtimeCertificateJson: runtimeCertificateJson,
      );
      await persistAuthority(
        merged,
        logicalId == LogicalConversationViewPolicy.bankedApplicationLogicalId ? runtimeCertificateJson : null,
      );
      final activated = await activateAuthority(merged);
      return LogicalCertificateAdvancementResult(
        disposition: activated
            ? LogicalCertificateAdvancementDisposition.committed
            : LogicalCertificateAdvancementDisposition.activationRejected,
        logicalId: logicalId,
        ledgerJson: merged,
      );
    } finally {
      if (identical(_mutex, mutex)) _mutex = null;
      if (!mutex.isCompleted) mutex.complete();
    }
  }
}
