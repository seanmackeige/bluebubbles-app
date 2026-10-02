import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/new_group_conversation.dart';
import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';
import 'package:bluebubbles/services/ui/chat/new_group_provider_contract.dart';

/// Crash-durable app store for the complete new-group journal.
///
/// Each state boundary replaces one preference value and is awaited before the
/// coordinator can cross the physical execution boundary. A missing value is
/// an empty journal; corrupt or schema-incompatible data throws and therefore
/// fails closed before provider execution.
class SharedPreferencesNewGroupOperationStore implements NewGroupOperationStore {
  const SharedPreferencesNewGroupOperationStore();

  @override
  Future<NewGroupOperationJournal> load() async {
    final raw = await PrefsSvc.messaging.loadNewGroupOperationJournalJsonFresh();
    if (raw == null) return NewGroupOperationJournal.empty();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('Invalid new-group journal');
    return NewGroupOperationJournal.fromJson(decoded.cast<String, dynamic>());
  }

  @override
  Future<void> save(NewGroupOperationJournal journal) async {
    final encoded = jsonEncode(journal.toJson());
    await PrefsSvc.messaging.saveNewGroupOperationJournalJson(encoded);
  }
}

/// Explicitly non-executing production adapter for the currently attested
/// stock Server 1.9.7/helper 0.0.19 path. It exists to make the release boundary
/// executable in code: the UI can inspect and explain the unsafe contract, but
/// no provider send method is wired until account, sender, and operation-ID
/// conditional authority are implemented server-side.
class Build100ProductionNewGroupBoundary {
  const Build100ProductionNewGroupBoundary._();

  static const NewGroupProviderCapabilityState capabilityState =
      NewGroupProviderCapabilityState.privateRouteAttestedUnsafeContract;

  static const bool executionEnabled = false;
}
