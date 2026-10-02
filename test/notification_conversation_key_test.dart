import 'package:bluebubbles/services/backend/notifications/desktop_notification.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical notification identity', () {
    test('Android notification ID is stable and disjoint from positive physical IDs', () {
      final logicalId = LogicalConversationId.certified('comcast-node-updates');

      final first = LogicalNotificationIdentity.fromLogicalId(logicalId).androidId;
      final second = LogicalNotificationIdentity.fromLogicalId(LogicalConversationId.parse(logicalId.value)).androidId;

      expect(first, second);
      expect(first, lessThan(0));
      expect(first, greaterThanOrEqualTo(-0x7fffffff));
      final other = LogicalNotificationIdentity.fromLogicalId(
        LogicalConversationId.ordinarySingleton('other-chat'),
      ).androidId;
      expect(first, isNot(other));
    });

    test('ordinary Android notification ID remains the physical chat database ID', () {
      expect(LogicalNotificationIdentity.androidIdForConversation(ordinaryPhysicalChatId: 73), 73);
    });

    test('certified conversation uses one logical Android notification ID', () {
      final logicalId = LogicalConversationId.certified('certified-human-conversation');
      expect(
        LogicalNotificationIdentity.androidIdForConversation(ordinaryPhysicalChatId: 73, certifiedLogicalId: logicalId),
        LogicalNotificationIdentity.fromLogicalId(logicalId).androidId,
      );
    });

    test('desktop v2 payload separates logical, navigation, source, and message identities', () {
      const data = DesktopMessageData(
        chatGuid: 'presentation-guid',
        conversationKey: 'logical:comcast-node-updates',
        sourceChatGuid: 'source-guid',
        messageGuid: 'message-guid',
        actions: <String>['mark-read'],
      );

      final decoded = DesktopMessageData.fromPayload(data.payload);

      expect(decoded, isNotNull);
      expect(decoded!.chatGuid, 'presentation-guid');
      expect(decoded.effectiveConversationKey, 'logical:comcast-node-updates');
      expect(decoded.sourceChatGuid, 'source-guid');
      expect(decoded.messageGuid, 'message-guid');
      expect(decoded.actions, <String>['mark-read']);
    });

    test('legacy desktop payload defaults conversation identity to chat GUID', () {
      final decoded = DesktopMessageData.fromJson(<String, dynamic>{
        'v': 1,
        'c': 'legacy-chat-guid',
        'm': 'message-guid',
        'a': <String>['mark-read'],
      });

      expect(decoded, isNotNull);
      expect(decoded!.conversationKey, isNull);
      expect(decoded.effectiveConversationKey, 'legacy-chat-guid');
      expect(decoded.chatGuid, 'legacy-chat-guid');
      expect(decoded.messageGuid, 'message-guid');
    });

    test('v2 desktop payload fails closed without a conversation key', () {
      expect(
        DesktopMessageData.fromJson(<String, dynamic>{
          'v': 2,
          'c': 'presentation-guid',
          'm': 'message-guid',
          'a': <String>[],
        }),
        isNull,
      );
    });

    test('v2 desktop payload fails closed without exact source provenance', () {
      expect(
        DesktopMessageData.fromJson(<String, dynamic>{
          'v': 2,
          'c': 'presentation-guid',
          'k': 'lc.v1.certified.logical-id',
          'a': const <String>[],
        }),
        isNull,
      );
    });
  });
}
