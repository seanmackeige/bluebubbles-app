import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical write-authority event classification', () {
    test('outbound content remains authority relevant', () {
      final message = Message(isFromMe: true, associatedMessageGuid: null);

      expect(message.isLogicalWriteAuthorityRelevant, isTrue);
    });

    test('inbound content never changes writer authority', () {
      final message = Message(isFromMe: false, associatedMessageGuid: null);

      expect(message.isLogicalWriteAuthorityRelevant, isFalse);
    });

    test('outbound tapback never changes writer authority', () {
      final message = Message(
        isFromMe: true,
        associatedMessageGuid: 'target-message',
        associatedMessageType: 'love',
      );

      expect(message.isTapback, isTrue);
      expect(message.isLogicalWriteAuthorityRelevant, isFalse);
    });

    test('outbound reply is not mistaken for a tapback', () {
      final message = Message(
        isFromMe: true,
        associatedMessageGuid: 'target-message',
        associatedMessageType: 'reply',
      );

      expect(message.isTapback, isFalse);
      expect(message.isLogicalWriteAuthorityRelevant, isTrue);
    });
  });
}
