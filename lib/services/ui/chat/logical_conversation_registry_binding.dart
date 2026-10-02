import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_registry.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:crypto/crypto.dart';

/// Pure adapter from independently certified read certificates and current
/// runtime observations into the generic application registry.
class LogicalConversationRegistryBinding {
  LogicalConversationRegistryBinding._();

  static String providerGuidFingerprint(String providerGuid) =>
      sha256.convert(utf8.encode('logical-provider-guid-v1\u0000$providerGuid')).toString();

  static bool sourceMatchesCertificate(
    LogicalConversationReadCertificate certificate, {
    required int? sourceChatRowId,
    required String providerGuid,
  }) {
    final proof = certificate.proofFor(sourceChatRowId);
    return proof != null && proof.sourceChatGuidSha256 == providerGuidFingerprint(providerGuid);
  }

  static LogicalConversationReadCertificate? certificateForSource(
    Iterable<LogicalConversationReadCertificate> certificates, {
    required int? sourceChatRowId,
    required String providerGuid,
  }) {
    final matches = certificates
        .where(
          (certificate) =>
              sourceMatchesCertificate(certificate, sourceChatRowId: sourceChatRowId, providerGuid: providerGuid),
        )
        .toList(growable: false);
    return matches.length == 1 ? matches.single : null;
  }

  static LogicalConversationRegistry bind({
    required Iterable<LogicalConversationReadCertificate> certificates,
    required Iterable<LogicalConversationPhysicalChatBinding> physicalChats,
  }) {
    final bindings = physicalChats.where((binding) => binding.isValid).toList(growable: false);
    final entries = <LogicalConversationRegistryEntry>[];
    for (final certificate in certificates) {
      if (!certificate.isValid) continue;
      final members = <LogicalConversationRegistryMember>[];
      for (final proof in certificate.members) {
        final matches = bindings
            .where(
              (binding) =>
                  binding.sourceChatRowId == proof.sourceChatRowId &&
                  binding.sourceChatGuidSha256 == proof.sourceChatGuidSha256,
            )
            .toList(growable: false);
        if (matches.length > 1) {
          throw StateError('LOGICAL_REGISTRY_RUNTIME_BINDING_AMBIGUOUS');
        }
        final binding = matches.isEmpty ? null : matches.single;
        // A temporarily unavailable repository member remains part of the
        // certified human conversation. Its privacy-safe provider fingerprint
        // keeps the registry topology intact, while absence of a runtime
        // binding prevents any physical mutation from targeting it.
        members.add(
          LogicalConversationRegistryMember(
            physicalRef: binding?.physicalRef ?? PhysicalConversationRef.fromFingerprint(proof.sourceChatGuidSha256),
            sourceChatRowId: binding?.sourceChatRowId,
            providerGuidFingerprint: proof.sourceChatGuidSha256,
            isPresentation: proof.sourceChatRowId == certificate.presentationSourceChatRowId,
            runtimeBindingAvailable: binding != null,
          ),
        );
      }
      entries.add(
        LogicalConversationRegistryEntry(logicalId: LogicalConversationId.certified(certificate.id), members: members),
      );
    }
    return LogicalConversationRegistry(entries);
  }

  /// Binds the row-independent authority ledger directly. Every certified
  /// member remains in the registry when temporarily absent; only a unique
  /// current provider match receives a runtime ROWID/physical reference.
  static LogicalConversationRegistry bindAuthorities({
    required Iterable<LogicalConversationCertificateAuthority> authorities,
    required Iterable<LogicalConversationPhysicalChatBinding> physicalChats,
  }) {
    final bindings = physicalChats.toList(growable: false);
    if (bindings.any((binding) => !binding.isValid)) {
      throw StateError('LOGICAL_REGISTRY_RUNTIME_BINDING_INVALID');
    }
    final entries = <LogicalConversationRegistryEntry>[];
    for (final authority in authorities) {
      final certificate = authority.certificate;
      final members = <LogicalConversationRegistryMember>[];
      for (final proof in certificate.members) {
        final matches = bindings
            .where((binding) => binding.sourceChatGuidSha256 == proof.sourceChatGuidSha256)
            .toList(growable: false);
        if (matches.length > 1) {
          throw StateError('LOGICAL_REGISTRY_RUNTIME_BINDING_AMBIGUOUS');
        }
        final binding = matches.isEmpty ? null : matches.single;
        members.add(
          LogicalConversationRegistryMember(
            physicalRef: binding?.physicalRef ?? PhysicalConversationRef.fromFingerprint(proof.sourceChatGuidSha256),
            sourceChatRowId: binding?.sourceChatRowId,
            providerGuidFingerprint: proof.sourceChatGuidSha256,
            isPresentation: proof.sourceChatGuidSha256 == certificate.presentationSourceChatGuidSha256,
            runtimeBindingAvailable: binding != null,
          ),
        );
      }
      entries.add(LogicalConversationRegistryEntry(logicalId: authority.logicalId, members: members));
    }
    return LogicalConversationRegistry(entries);
  }

  /// Public-safe material for restart/cache-loss property checks.
  static String stableBindingMaterial(LogicalConversationRegistry registry) => jsonEncode(<String, dynamic>{
    'schema': logicalConversationRegistrySchema,
    'registry_fingerprint': registry.stableFingerprint,
    'logical_ids': registry.entries.map((entry) => entry.logicalId.value).toList(growable: false),
  });
}
