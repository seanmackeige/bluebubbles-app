import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_platform_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical platform cleanup', () {
    test('share cleanup covers every physical member and protects logical keys', () {
      final logicalId = LogicalConversationId.certified('logical-alpha');

      expect(
        LogicalPlatformCleanupPlan.shareTargetCandidates(<String>['physical-b', '', 'physical-a', 'physical-b']),
        <String>{'physical-a', 'physical-b'},
      );
      expect(
        LogicalPlatformCleanupPlan.protectedShareTargetKeys(<LogicalConversationId>[
          logicalId,
          LogicalConversationId.ordinarySingleton('ordinary'),
        ]),
        <String>{logicalId.value},
      );
    });

    test('completed read cleanup includes logical and every valid legacy notification ID', () {
      final logicalId = LogicalConversationId.certified('logical-alpha');
      final logicalNotificationId = LogicalNotificationIdentity.fromLogicalId(logicalId).androidId;

      expect(
        LogicalPlatformCleanupPlan.notificationIds(
          logicalId: logicalId,
          legacyPhysicalIds: <int?>[41, null, 0, 42, 41],
        ),
        <int>{logicalNotificationId, 41, 42},
      );
    });
  });
}
