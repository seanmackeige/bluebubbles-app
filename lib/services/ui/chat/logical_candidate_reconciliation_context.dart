import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:crypto/crypto.dart';

const logicalCandidateReconciliationContextSchema = 'LOGICAL_CANDIDATE_RECONCILIATION_CONTEXT_V1';

final RegExp _candidateContextFingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

String _fingerprint(String namespace, String value) => sha256.convert(utf8.encode('$namespace\u0000$value')).toString();

dynamic _canonicalJson(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList(growable: false)..sort();
    return <String, dynamic>{for (final key in keys) key: _canonicalJson(value[key])};
  }
  if (value is List) return value.map(_canonicalJson).toList(growable: false);
  return value;
}

String? _normalizedAddressFingerprint(LogicalAddressEvidence address) {
  final normalized = LogicalConversationOutboundRoutePolicy.normalizeRoutableAddress(address);
  return normalized == null ? null : _fingerprint('logical-candidate-address-v1', normalized);
}

/// One certified physical source used only to derive a privacy-safe candidate
/// nomination context. This does not grant read membership or write authority.
class LogicalCandidateContextSource {
  const LogicalCandidateContextSource({required this.service, required this.participants});

  final String service;
  final List<LogicalAddressEvidence> participants;
}

/// Privacy-safe exact-set context for nominating a possible new physical
/// representation of one already-certified human conversation.
///
/// The context may suppress/quarantine a candidate while independent provider
/// evidence is collected. It can never add a member to a read certificate.
class LogicalCandidateReconciliationContext implements Comparable<LogicalCandidateReconciliationContext> {
  LogicalCandidateReconciliationContext({
    required this.targetLogicalId,
    required this.certificateRevision,
    required Iterable<String> externalParticipantFingerprints,
    required Iterable<String> vettedAliasFingerprints,
    required Iterable<String> services,
    required this.providerAccountFingerprint,
  }) : externalParticipantFingerprints = Set<String>.unmodifiable(externalParticipantFingerprints),
       vettedAliasFingerprints = Set<String>.unmodifiable(vettedAliasFingerprints),
       services = Set<String>.unmodifiable(services) {
    if (!targetLogicalId.isCertified) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_TARGET_NOT_CERTIFIED');
    }
    if (!_candidateContextFingerprintPattern.hasMatch(certificateRevision)) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_CERTIFICATE_REVISION_INVALID');
    }
    if (this.externalParticipantFingerprints.isEmpty ||
        this.externalParticipantFingerprints.length > 256 ||
        this.externalParticipantFingerprints.any((value) => !_candidateContextFingerprintPattern.hasMatch(value))) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_EXTERNAL_SET_INVALID');
    }
    if (this.vettedAliasFingerprints.length > 64 ||
        this.vettedAliasFingerprints.any((value) => !_candidateContextFingerprintPattern.hasMatch(value))) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_ALIAS_SET_INVALID');
    }
    if (this.services.isEmpty ||
        this.services.length > 8 ||
        this.services.any((service) => service.isEmpty || service.length > 64)) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_SERVICE_SET_INVALID');
    }
    if (providerAccountFingerprint != null &&
        !_candidateContextFingerprintPattern.hasMatch(providerAccountFingerprint!)) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_ACCOUNT_INVALID');
    }
    if (this.externalParticipantFingerprints.intersection(this.vettedAliasFingerprints).isNotEmpty) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_EXTERNAL_ALIAS_OVERLAP');
    }
  }

  final LogicalConversationId targetLogicalId;
  final String certificateRevision;
  final Set<String> externalParticipantFingerprints;
  final Set<String> vettedAliasFingerprints;
  final Set<String> services;
  final String? providerAccountFingerprint;

  bool get providerBacked => providerAccountFingerprint != null;

  static LogicalCandidateReconciliationContext? derive({
    required LogicalConversationId targetLogicalId,
    required String certificateRevision,
    required Iterable<LogicalCandidateContextSource> certifiedSources,
    required Iterable<LogicalAddressEvidence> vettedAliases,
    required String? providerAccountFingerprint,
  }) {
    final aliases = <String>{};
    for (final alias in vettedAliases) {
      final fingerprint = _normalizedAddressFingerprint(alias);
      if (fingerprint == null || !aliases.add(fingerprint)) return null;
    }

    Set<String>? acceptedExternal;
    final services = <String>{};
    final sources = certifiedSources.toList(growable: false);
    if (sources.isEmpty) return null;
    for (final source in sources) {
      if (source.service.isEmpty) return null;
      services.add(source.service);
      final normalized = <String>{};
      for (final participant in source.participants) {
        final fingerprint = _normalizedAddressFingerprint(participant);
        if (fingerprint == null || !normalized.add(fingerprint)) return null;
      }
      final external = normalized.difference(aliases);
      if (external.isEmpty) return null;
      if (acceptedExternal == null) {
        acceptedExternal = external;
      } else if (acceptedExternal.length != external.length || !acceptedExternal.containsAll(external)) {
        return null;
      }
    }

    return LogicalCandidateReconciliationContext(
      targetLogicalId: targetLogicalId,
      certificateRevision: certificateRevision,
      externalParticipantFingerprints: acceptedExternal!,
      vettedAliasFingerprints: aliases,
      services: services,
      providerAccountFingerprint: providerAccountFingerprint,
    );
  }

  bool matchesCandidate({required String service, required Iterable<LogicalAddressEvidence> participants}) {
    if (!services.contains(service)) return false;
    final normalized = <String>{};
    for (final participant in participants) {
      final fingerprint = _normalizedAddressFingerprint(participant);
      if (fingerprint == null || !normalized.add(fingerprint)) return false;
    }
    final external = normalized.difference(vettedAliasFingerprints);
    return external.length == externalParticipantFingerprints.length &&
        external.containsAll(externalParticipantFingerprints);
  }

  Map<String, dynamic> _unsignedJson() => <String, dynamic>{
    'targetLogicalId': targetLogicalId.toJson(),
    'certificateRevision': certificateRevision,
    'externalParticipantFingerprints': externalParticipantFingerprints.toList(growable: false)..sort(),
    'vettedAliasFingerprints': vettedAliasFingerprints.toList(growable: false)..sort(),
    'services': services.toList(growable: false)..sort(),
    'providerAccountFingerprint': providerAccountFingerprint,
  };

  String get stableFingerprint => sha256.convert(utf8.encode(jsonEncode(_canonicalJson(_unsignedJson())))).toString();

  Map<String, dynamic> toJson() => <String, dynamic>{..._unsignedJson(), 'stableFingerprint': stableFingerprint};

  factory LogicalCandidateReconciliationContext.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key) {
      final raw = json[key];
      if (raw is! List || raw.any((value) => value is! String)) {
        throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_LIST_INVALID');
      }
      return raw.cast<String>();
    }

    final rawLogicalId = json['targetLogicalId'];
    final rawCertificateRevision = json['certificateRevision'];
    final rawAccount = json['providerAccountFingerprint'];
    if (rawLogicalId is! Map || rawCertificateRevision is! String || (rawAccount != null && rawAccount is! String)) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_INVALID');
    }
    final context = LogicalCandidateReconciliationContext(
      targetLogicalId: LogicalConversationId.fromJson(rawLogicalId.cast<String, dynamic>()),
      certificateRevision: rawCertificateRevision,
      externalParticipantFingerprints: strings('externalParticipantFingerprints'),
      vettedAliasFingerprints: strings('vettedAliasFingerprints'),
      services: strings('services'),
      providerAccountFingerprint: rawAccount as String?,
    );
    if (json['stableFingerprint'] != context.stableFingerprint) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_FINGERPRINT_INVALID');
    }
    return context;
  }

  @override
  int compareTo(LogicalCandidateReconciliationContext other) => targetLogicalId.compareTo(other.targetLogicalId);
}

enum LogicalCandidateContextMatchKind { none, unique, ambiguous }

class LogicalCandidateContextMatch {
  const LogicalCandidateContextMatch._(this.kind, this.targets);

  const LogicalCandidateContextMatch.none()
    : this._(LogicalCandidateContextMatchKind.none, const <LogicalConversationId>[]);

  LogicalCandidateContextMatch.unique(LogicalConversationId target)
    : this._(
        LogicalCandidateContextMatchKind.unique,
        List<LogicalConversationId>.unmodifiable(<LogicalConversationId>[target]),
      );

  LogicalCandidateContextMatch.ambiguous(Iterable<LogicalConversationId> targets)
    : this._(
        LogicalCandidateContextMatchKind.ambiguous,
        List<LogicalConversationId>.unmodifiable(targets.toList(growable: false)..sort()),
      );

  final LogicalCandidateContextMatchKind kind;
  final List<LogicalConversationId> targets;

  LogicalConversationId? get uniqueTarget => kind == LogicalCandidateContextMatchKind.unique ? targets.single : null;
}

class LogicalCandidateReconciliationContextLedger {
  LogicalCandidateReconciliationContextLedger(Iterable<LogicalCandidateReconciliationContext> contexts)
    : contexts = List<LogicalCandidateReconciliationContext>.unmodifiable(contexts.toList(growable: false)..sort()) {
    final ids = this.contexts.map((context) => context.targetLogicalId).toSet();
    if (ids.length != this.contexts.length) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_DUPLICATE_TARGET');
    }
  }

  factory LogicalCandidateReconciliationContextLedger.empty() =>
      LogicalCandidateReconciliationContextLedger(const <LogicalCandidateReconciliationContext>[]);

  final List<LogicalCandidateReconciliationContext> contexts;

  LogicalCandidateReconciliationContext? contextFor(LogicalConversationId logicalId) {
    for (final context in contexts) {
      if (context.targetLogicalId == logicalId) return context;
    }
    return null;
  }

  LogicalCandidateReconciliationContextLedger upsert(LogicalCandidateReconciliationContext context) =>
      LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        for (final current in contexts)
          if (current.targetLogicalId != context.targetLogicalId) current,
        context,
      ]);

  /// Keeps only contexts whose target still exists in the authoritative
  /// certificate ledger. A stale certificate revision may remain useful as a
  /// conservative mutation-protection hint, but it can never authorize a new
  /// nomination or certificate advancement.
  LogicalCandidateReconciliationContextLedger retainTargets(Iterable<LogicalConversationId> targets) {
    final accepted = targets.toSet();
    return LogicalCandidateReconciliationContextLedger(
      contexts.where((context) => accepted.contains(context.targetLogicalId)),
    );
  }

  bool isCurrent(LogicalCandidateReconciliationContext context, String certificateRevision) =>
      context.certificateRevision == certificateRevision;

  LogicalCandidateContextMatch matchCandidate({
    required String service,
    required Iterable<LogicalAddressEvidence> participants,
  }) {
    final matches = contexts
        .where((context) => context.matchesCandidate(service: service, participants: participants))
        .map((context) => context.targetLogicalId)
        .toList(growable: false);
    if (matches.isEmpty) return const LogicalCandidateContextMatch.none();
    if (matches.length == 1) {
      return LogicalCandidateContextMatch.unique(matches.single);
    }
    return LogicalCandidateContextMatch.ambiguous(matches);
  }

  Map<String, dynamic> _unsignedJson() => <String, dynamic>{
    'schema': logicalCandidateReconciliationContextSchema,
    'contexts': <String, dynamic>{for (final context in contexts) context.targetLogicalId.value: context.toJson()},
  };

  String get revision => sha256.convert(utf8.encode(jsonEncode(_canonicalJson(_unsignedJson())))).toString();

  Map<String, dynamic> toJson() => <String, dynamic>{..._unsignedJson(), 'revision': revision};

  String encode() => jsonEncode(_canonicalJson(toJson()));

  factory LogicalCandidateReconciliationContextLedger.decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_LEDGER_INVALID');
    }
    final json = decoded.cast<String, dynamic>();
    final rawContexts = json['contexts'];
    if (json['schema'] != logicalCandidateReconciliationContextSchema || rawContexts is! Map) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_LEDGER_INVALID');
    }
    final contexts = <LogicalCandidateReconciliationContext>[];
    for (final entry in rawContexts.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_LEDGER_RECORD_INVALID');
      }
      final context = LogicalCandidateReconciliationContext.fromJson((entry.value as Map).cast<String, dynamic>());
      if (context.targetLogicalId.value != entry.key) {
        throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_LEDGER_TARGET_MISMATCH');
      }
      contexts.add(context);
    }
    final ledger = LogicalCandidateReconciliationContextLedger(contexts);
    if (json['revision'] != ledger.revision) {
      throw const FormatException('LOGICAL_CANDIDATE_CONTEXT_LEDGER_REVISION_INVALID');
    }
    return ledger;
  }
}
