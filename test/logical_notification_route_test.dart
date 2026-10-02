import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_notification_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_platform_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notification conversation admission', () {
    test('ordinary source retains exact legacy identity', () {
      expect(
        LogicalNotificationRoutePolicy.admits(
          admittedConversationKey: 'physical-a',
          admittedSourceChatGuid: 'physical-a',
          currentSourceChatGuid: 'physical-a',
          currentConversationKey: 'physical-a',
          currentSourceIsCertified: false,
          presentationResolvesToConversationKey: true,
        ),
        isTrue,
      );
    });

    test('certified source requires the exact logical key and exact source', () {
      const logicalKey = 'lc.v1.certified.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      expect(
        LogicalNotificationRoutePolicy.admits(
          admittedConversationKey: logicalKey,
          admittedSourceChatGuid: 'physical-a',
          currentSourceChatGuid: 'physical-a',
          currentConversationKey: logicalKey,
          currentSourceIsCertified: true,
          presentationResolvesToConversationKey: true,
        ),
        isTrue,
      );
      expect(
        LogicalNotificationRoutePolicy.admits(
          admittedConversationKey: logicalKey,
          admittedSourceChatGuid: 'physical-a',
          currentSourceChatGuid: 'physical-b',
          currentConversationKey: logicalKey,
          currentSourceIsCertified: true,
          presentationResolvesToConversationKey: true,
        ),
        isFalse,
      );
    });

    test('missing certificate cannot degrade a logical envelope to physical', () {
      const logicalKey = 'lc.v1.certified.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      expect(
        LogicalNotificationRoutePolicy.admits(
          admittedConversationKey: logicalKey,
          admittedSourceChatGuid: 'physical-a',
          currentSourceChatGuid: 'physical-a',
          currentConversationKey: 'physical-a',
          currentSourceIsCertified: false,
          presentationResolvesToConversationKey: false,
        ),
        isFalse,
      );
    });

    test('formerly ordinary envelope cannot mutate a newly certified source', () {
      expect(
        LogicalNotificationRoutePolicy.admits(
          admittedConversationKey: 'physical-a',
          admittedSourceChatGuid: 'physical-a',
          currentSourceChatGuid: 'physical-a',
          currentConversationKey: 'lc.v1.certified.cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
          currentSourceIsCertified: true,
          presentationResolvesToConversationKey: false,
        ),
        isFalse,
      );
    });
  });

  group('Android notification collision and migration policy', () {
    test('logical IDs and tags are disjoint from ordinary notification identity', () {
      final logicalId = LogicalConversationId.certified('notification-collision-fixture');
      final identity = LogicalNotificationIdentity.fromLogicalId(logicalId);
      const ordinaryTag = 'com.mackeige.bluebubbles.NEW_MESSAGE_NOTIFICATION';

      expect(identity.androidId, lessThan(0));
      expect(LogicalNotificationIdentity.androidIdForConversation(ordinaryPhysicalChatId: 1), 1);
      expect(
        LogicalNotificationIdentity.androidTagForConversation(ordinaryTag: ordinaryTag, certifiedLogicalId: logicalId),
        isNot(ordinaryTag),
      );
    });

    test('cleanup covers current logical, old logical, and every physical identity', () {
      final logicalId = LogicalConversationId.certified('notification-migration-fixture');
      const ordinaryTag = 'com.mackeige.bluebubbles.NEW_MESSAGE_NOTIFICATION';
      final targets = LogicalPlatformCleanupPlan.notificationTargets(
        logicalId: logicalId,
        legacyPhysicalIds: const <int?>[11, 12, 11, null],
        ordinaryTag: ordinaryTag,
      );

      expect(
        targets,
        contains(
          LogicalNotificationCleanupTarget(
            id: LogicalNotificationIdentity.fromLogicalId(logicalId).androidId,
            tag: LogicalNotificationIdentity.androidTagForConversation(
              ordinaryTag: ordinaryTag,
              certifiedLogicalId: logicalId,
            ),
          ),
        ),
      );
      expect(
        targets,
        contains(
          LogicalNotificationCleanupTarget(
            id: LogicalNotificationIdentity.legacyPositiveAndroidIdForLogicalId(logicalId),
            tag: ordinaryTag,
          ),
        ),
      );
      expect(targets, contains(const LogicalNotificationCleanupTarget(id: 11, tag: ordinaryTag)));
      expect(targets, contains(const LogicalNotificationCleanupTarget(id: 12, tag: ordinaryTag)));
      expect(targets.toSet().length, targets.length);
    });
  });
}
