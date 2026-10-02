import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter/foundation.dart';

/// Read-only ObjectBox adapter for the generic fingerprint trust-anchor.
///
/// It performs no writes and retains no raw provider GUID after the binding
/// observation has been converted to its stable fingerprint.
class LogicalConversationDatabaseCertificateBinding {
  LogicalConversationDatabaseCertificateBinding._();

  static List<LogicalConversationPhysicalChatBinding> readCurrentBindings() {
    if (kIsWeb) return const <LogicalConversationPhysicalChatBinding>[];
    try {
      return <LogicalConversationPhysicalChatBinding>[
        for (final chat in Database.chats.getAll())
          if (chat.originalROWID != null && chat.originalROWID! > 0 && chat.guid.isNotEmpty)
            LogicalConversationPhysicalChatBinding.fromProviderGuid(
              sourceChatRowId: chat.originalROWID!,
              sourceChatGuid: chat.guid,
            ),
      ];
    } catch (_) {
      return const <LogicalConversationPhysicalChatBinding>[];
    }
  }

  static bool bindPersistedCertificates({
    required String? persistedLedgerJson,
    required String? legacyCertificateJson,
  }) => LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
    physicalChats: readCurrentBindings(),
    persistedLedgerJson: persistedLedgerJson,
    legacyCertificateJson: legacyCertificateJson,
  );

  /// Re-evaluates the already-validated in-memory V2 authority against the
  /// current read-only provider inventory. The optional arriving binding
  /// closes the narrow gap where addChat is invoked before the DB query sees
  /// the new row. Exact duplicates are removed; conflicting rows/GUIDs remain
  /// visible to the policy's fail-closed collision checks.
  static bool rebindActiveCertificates({
    Iterable<LogicalConversationPhysicalChatBinding> arrivingBindings =
        const <LogicalConversationPhysicalChatBinding>[],
  }) {
    if (!LogicalConversationViewPolicy.certificateLedgerValid) return false;
    final bindings = readCurrentBindings().toList(growable: true);
    for (final arriving in arrivingBindings) {
      final exactDuplicate = bindings.any(
        (current) =>
            current.sourceChatRowId == arriving.sourceChatRowId &&
            current.sourceChatGuidSha256 == arriving.sourceChatGuidSha256,
      );
      if (!exactDuplicate) bindings.add(arriving);
    }
    return LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
      physicalChats: bindings,
      persistedLedgerJson: LogicalConversationViewPolicy.encodeActiveCertificateLedger(),
      legacyCertificateJson: null,
    );
  }

  /// Compatibility entry point used by runtime certificate advancement in an
  /// already initialized isolate. It replaces only the matching ledger entry
  /// and retains every other certified human conversation.
  static bool bindPersistedCertificate(String? persistedCertificateJson) {
    final bindings = readCurrentBindings();
    if (persistedCertificateJson != null && LogicalConversationViewPolicy.certificateLedgerValid) {
      try {
        final mergedLedger = LogicalConversationViewPolicy.mergeRuntimeCertificateIntoLedger(
          persistedLedgerJson: LogicalConversationViewPolicy.encodeActiveCertificateLedger(),
          runtimeCertificateJson: persistedCertificateJson,
        );
        return LogicalConversationViewPolicy.bindRuntimeCertificateLedger(
          physicalChats: bindings,
          persistedLedgerJson: mergedLedger,
          legacyCertificateJson: null,
        );
      } catch (_) {
        return false;
      }
    }
    return LogicalConversationViewPolicy.bindRuntimeCertificate(
      physicalChats: bindings,
      persistedCertificateJson: persistedCertificateJson,
    );
  }
}
