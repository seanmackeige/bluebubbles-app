import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:crypto/crypto.dart';

const logicalConversationRegistrySchema = 'LOGICAL_CONVERSATION_REGISTRY_V1';

final RegExp _registryFingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

/// One independently certified physical member with its current local binding.
/// Raw provider identifiers and participant values are never retained.
class LogicalConversationRegistryMember implements Comparable<LogicalConversationRegistryMember> {
  LogicalConversationRegistryMember({
    required this.physicalRef,
    required this.sourceChatRowId,
    required this.providerGuidFingerprint,
    required this.isPresentation,
    this.runtimeBindingAvailable = true,
  }) {
    if (runtimeBindingAvailable && (sourceChatRowId == null || sourceChatRowId! <= 0)) {
      throw ArgumentError.value(sourceChatRowId, 'sourceChatRowId', 'must be positive when runtime-bound');
    }
    if (!runtimeBindingAvailable && sourceChatRowId != null) {
      throw StateError('LOGICAL_REGISTRY_UNAVAILABLE_MEMBER_RUNTIME_ROW_PRESENT');
    }
    if (!_registryFingerprintPattern.hasMatch(providerGuidFingerprint)) {
      throw const FormatException('Registry provider binding must be a lowercase SHA-256 fingerprint');
    }
    if (!runtimeBindingAvailable && physicalRef != certifiedRef) {
      throw StateError('LOGICAL_REGISTRY_UNAVAILABLE_MEMBER_RUNTIME_REF_PRESENT');
    }
  }

  /// Compatibility runtime provenance. Application identity must use
  /// [certifiedRef], whose hash namespace is stable while the member is absent.
  final PhysicalConversationRef physicalRef;
  final int? sourceChatRowId;
  final String providerGuidFingerprint;
  final bool isPresentation;
  final bool runtimeBindingAvailable;

  PhysicalConversationRef get certifiedRef => PhysicalConversationRef.fromFingerprint(providerGuidFingerprint);

  PhysicalConversationRef? get runtimePhysicalRef => runtimeBindingAvailable ? physicalRef : null;

  @override
  int compareTo(LogicalConversationRegistryMember other) {
    final providerOrder = providerGuidFingerprint.compareTo(other.providerGuidFingerprint);
    return providerOrder != 0 ? providerOrder : certifiedRef.compareTo(other.certifiedRef);
  }
}

/// A certified human conversation. Membership is closed and explicit: no
/// display name, participant similarity, or message activity can add a member.
class LogicalConversationRegistryEntry {
  LogicalConversationRegistryEntry({
    required this.logicalId,
    required Iterable<LogicalConversationRegistryMember> members,
  }) : members = List<LogicalConversationRegistryMember>.unmodifiable(members.toList(growable: false)..sort()) {
    if (!logicalId.isCertified) {
      throw ArgumentError.value(logicalId, 'logicalId', 'must be certified');
    }
    if (this.members.length < 2 || this.members.length > LogicalConversationSnapshot.maxMembers) {
      throw ArgumentError.value(this.members.length, 'members', 'must contain 2 to 256 certified members');
    }
    if (this.members.where((member) => member.isPresentation).length != 1) {
      throw StateError('LOGICAL_REGISTRY_PRESENTATION_MEMBER_INVALID');
    }
    final availableCount = this.members.where((member) => member.runtimeBindingAvailable).length;
    if (certifiedMemberRefs.length != this.members.length ||
        runtimePhysicalRefs.length != availableCount ||
        sourceChatRowIds.length != availableCount ||
        providerGuidFingerprints.length != this.members.length) {
      throw StateError('LOGICAL_REGISTRY_DUPLICATE_MEMBER_BINDING');
    }
  }

  final LogicalConversationId logicalId;
  final List<LogicalConversationRegistryMember> members;

  /// Runtime compatibility set. It is not stable while members are absent.
  Set<PhysicalConversationRef> get physicalRefs => members.map((member) => member.physicalRef).toSet();

  /// Stable certified application membership across cache loss and temporary
  /// runtime absence.
  Set<PhysicalConversationRef> get certifiedMemberRefs => members.map((member) => member.certifiedRef).toSet();

  Set<PhysicalConversationRef> get runtimePhysicalRefs =>
      members.map((member) => member.runtimePhysicalRef).nonNulls.toSet();

  Set<int> get sourceChatRowIds => members.map((member) => member.sourceChatRowId).nonNulls.toSet();
  Set<String> get providerGuidFingerprints => members.map((member) => member.providerGuidFingerprint).toSet();

  LogicalConversationRegistryMember get presentationMember => members.singleWhere((member) => member.isPresentation);

  LogicalConversationRegistryMember? memberForPhysicalRef(PhysicalConversationRef ref) {
    for (final member in members) {
      if (member.runtimePhysicalRef == ref) return member;
    }
    return null;
  }

  LogicalConversationRegistryMember? memberForSourceRowId(int? sourceChatRowId) {
    if (sourceChatRowId == null) return null;
    for (final member in members) {
      if (member.sourceChatRowId == sourceChatRowId) return member;
    }
    return null;
  }

  LogicalConversationRegistryMember? memberForRuntimeBinding({
    required PhysicalConversationRef physicalRef,
    required int sourceChatRowId,
  }) {
    final member = memberForSourceRowId(sourceChatRowId);
    return member?.runtimePhysicalRef == physicalRef ? member : null;
  }

  PhysicalConversationRef? certifiedRefForRuntimeBinding({
    required PhysicalConversationRef physicalRef,
    required int sourceChatRowId,
  }) => memberForRuntimeBinding(physicalRef: physicalRef, sourceChatRowId: sourceChatRowId)?.certifiedRef;

  bool containsRuntimeBinding({required PhysicalConversationRef physicalRef, required int sourceChatRowId}) {
    return memberForRuntimeBinding(physicalRef: physicalRef, sourceChatRowId: sourceChatRowId) != null;
  }

  /// Stable across observation order and local ROWID reallocation.
  String get stableFingerprint {
    final providerFingerprints = providerGuidFingerprints.toList(growable: false)..sort();
    final material = <String>[
      logicalConversationRegistrySchema,
      logicalId.value,
      presentationMember.providerGuidFingerprint,
      ...providerFingerprints,
    ];
    return sha256.convert(utf8.encode(material.join('\u0000'))).toString();
  }

  /// Canonical application snapshot factory for registry-backed projections.
  LogicalConversationSnapshot snapshot({
    required LogicalConversationHealth health,
    required LogicalUnreadLedger unreadLedger,
    required Iterable<LogicalSearchResult> searchResults,
    required Iterable<LogicalMediaItem> mediaItems,
    required int revision,
  }) {
    return LogicalConversationSnapshot(
      logicalId: logicalId,
      members: certifiedMemberRefs,
      health: health,
      unreadLedger: unreadLedger,
      searchResults: searchResults,
      mediaItems: mediaItems,
      revision: revision,
    );
  }
}

/// Immutable registry of independently certified human conversations.
///
/// Reverse maps are constructed only after proving that logical IDs, physical
/// references, provider fingerprints, and runtime rows are globally disjoint.
class LogicalConversationRegistry {
  LogicalConversationRegistry(Iterable<LogicalConversationRegistryEntry> entries)
    : entries = List<LogicalConversationRegistryEntry>.unmodifiable(
        entries.toList(growable: false)..sort((left, right) => left.logicalId.compareTo(right.logicalId)),
      ) {
    for (final entry in this.entries) {
      if (_byLogicalId.putIfAbsent(entry.logicalId, () => entry) != entry) {
        throw StateError('LOGICAL_REGISTRY_DUPLICATE_LOGICAL_ID');
      }
      for (final member in entry.members) {
        final runtimePhysicalRef = member.runtimePhysicalRef;
        final sourceChatRowId = member.sourceChatRowId;
        final physicalConflict =
            runtimePhysicalRef != null && _byPhysicalRef.putIfAbsent(runtimePhysicalRef, () => entry) != entry;
        if (physicalConflict ||
            (sourceChatRowId != null && _bySourceRowId.putIfAbsent(sourceChatRowId, () => entry) != entry) ||
            _byProviderGuidFingerprint.putIfAbsent(member.providerGuidFingerprint, () => entry) != entry) {
          throw StateError('LOGICAL_REGISTRY_CROSS_CONVERSATION_MEMBER_COLLISION');
        }
      }
    }
  }

  LogicalConversationRegistry.empty() : this(const <LogicalConversationRegistryEntry>[]);

  final List<LogicalConversationRegistryEntry> entries;
  final Map<LogicalConversationId, LogicalConversationRegistryEntry> _byLogicalId =
      <LogicalConversationId, LogicalConversationRegistryEntry>{};
  final Map<PhysicalConversationRef, LogicalConversationRegistryEntry> _byPhysicalRef =
      <PhysicalConversationRef, LogicalConversationRegistryEntry>{};
  final Map<int, LogicalConversationRegistryEntry> _bySourceRowId = <int, LogicalConversationRegistryEntry>{};
  final Map<String, LogicalConversationRegistryEntry> _byProviderGuidFingerprint =
      <String, LogicalConversationRegistryEntry>{};

  bool get isEmpty => entries.isEmpty;

  LogicalConversationRegistryEntry? entryForLogicalId(LogicalConversationId logicalId) => _byLogicalId[logicalId];

  LogicalConversationRegistryEntry? entryForPhysicalRef(PhysicalConversationRef physicalRef) =>
      _byPhysicalRef[physicalRef];

  LogicalConversationRegistryEntry? entryForSourceRowId(int? sourceChatRowId) =>
      sourceChatRowId == null ? null : _bySourceRowId[sourceChatRowId];

  LogicalConversationRegistryEntry? entryForProviderGuidFingerprint(String fingerprint) =>
      _byProviderGuidFingerprint[fingerprint];

  LogicalConversationRegistryEntry? entryForRuntimeBinding({
    required PhysicalConversationRef physicalRef,
    required int sourceChatRowId,
  }) {
    final byRef = _byPhysicalRef[physicalRef];
    final byRow = _bySourceRowId[sourceChatRowId];
    return identical(byRef, byRow) &&
            byRef?.containsRuntimeBinding(physicalRef: physicalRef, sourceChatRowId: sourceChatRowId) == true
        ? byRef
        : null;
  }

  LogicalConversationId? logicalIdForPhysicalRef(PhysicalConversationRef physicalRef) =>
      entryForPhysicalRef(physicalRef)?.logicalId;

  /// Collapses each independently certified member set without allowing one
  /// registry entry to absorb or suppress a member of another entry.
  List<T> projectConversationList<T>(Iterable<T> items, int? Function(T item) sourceRowIdOf) {
    var projected = List<T>.from(items);
    for (final entry in entries) {
      final counts = <int, int>{};
      for (final item in projected) {
        final rowId = sourceRowIdOf(item);
        if (rowId != null && entry.sourceChatRowIds.contains(rowId)) {
          counts.update(rowId, (value) => value + 1, ifAbsent: () => 1);
        }
      }
      if (counts.isEmpty || counts.values.any((count) => count != 1)) continue;
      final presentRows = counts.keys.toSet();
      final presentationRow = entry.presentationMember.sourceChatRowId;
      final selectedRow = presentationRow != null && presentRows.contains(presentationRow)
          ? presentationRow
          : entry.members
                .firstWhere((member) => member.sourceChatRowId != null && presentRows.contains(member.sourceChatRowId))
                .sourceChatRowId!;
      projected = projected
          .where((item) {
            final rowId = sourceRowIdOf(item);
            return !entry.sourceChatRowIds.contains(rowId) || rowId == selectedRow;
          })
          .toList(growable: false);
    }
    return projected;
  }

  /// Stable across entry/member order and local runtime row allocation.
  String get stableFingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'schema': logicalConversationRegistrySchema,
            'entries': entries.map((entry) => entry.stableFingerprint).toList(growable: false),
          }),
        ),
      )
      .toString();
}
