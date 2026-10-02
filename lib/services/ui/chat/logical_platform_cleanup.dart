import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';

class LogicalNotificationCleanupTarget implements Comparable<LogicalNotificationCleanupTarget> {
  const LogicalNotificationCleanupTarget({required this.id, required this.tag});

  final int id;
  final String tag;

  @override
  int compareTo(LogicalNotificationCleanupTarget other) {
    final tagOrder = tag.compareTo(other.tag);
    return tagOrder != 0 ? tagOrder : id.compareTo(other.id);
  }

  @override
  bool operator ==(Object other) => other is LogicalNotificationCleanupTarget && other.id == id && other.tag == tag;

  @override
  int get hashCode => Object.hash(id, tag);
}

/// Pure cleanup identities for platform surfaces that historically keyed a
/// certified human conversation by one of its physical provider members.
class LogicalPlatformCleanupPlan {
  const LogicalPlatformCleanupPlan._();

  static Set<String> shareTargetCandidates(Iterable<String> physicalGuids) =>
      physicalGuids.where((value) => value.isNotEmpty).toSet();

  static Set<String> protectedShareTargetKeys(Iterable<LogicalConversationId> logicalIds) =>
      logicalIds.where((value) => value.isCertified).map((value) => value.value).toSet();

  static Set<int> notificationIds({
    required LogicalConversationId logicalId,
    required Iterable<int?> legacyPhysicalIds,
  }) => <int>{
    LogicalNotificationIdentity.fromLogicalId(logicalId).androidId,
    ...legacyPhysicalIds.whereType<int>().where((value) => value > 0),
  };

  static List<LogicalNotificationCleanupTarget> notificationTargets({
    required LogicalConversationId logicalId,
    required Iterable<int?> legacyPhysicalIds,
    required String ordinaryTag,
  }) {
    final targets = <LogicalNotificationCleanupTarget>{
      LogicalNotificationCleanupTarget(
        id: LogicalNotificationIdentity.fromLogicalId(logicalId).androidId,
        tag: LogicalNotificationIdentity.androidTagForConversation(
          ordinaryTag: ordinaryTag,
          certifiedLogicalId: logicalId,
        ),
      ),
      LogicalNotificationCleanupTarget(
        id: LogicalNotificationIdentity.legacyPositiveAndroidIdForLogicalId(logicalId),
        tag: ordinaryTag,
      ),
      for (final id in legacyPhysicalIds.whereType<int>().where((value) => value > 0))
        LogicalNotificationCleanupTarget(id: id, tag: ordinaryTag),
    }.toList()..sort();
    return targets;
  }
}
