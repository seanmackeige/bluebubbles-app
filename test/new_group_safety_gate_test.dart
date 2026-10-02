import 'package:bluebubbles/services/ui/chat/new_group_safety_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NewGroupSafetyGate', () {
    test('allows one-to-one creation', () {
      expect(
        NewGroupSafetyGate.evaluate(exactRecipientCount: 1, existingConversationResolved: false),
        NewConversationExecutionDisposition.oneToOneAllowed,
      );
    });

    test('allows an exactly resolved existing group', () {
      expect(
        NewGroupSafetyGate.evaluate(exactRecipientCount: 8, existingConversationResolved: true),
        NewConversationExecutionDisposition.existingConversationAllowed,
      );
    });

    test('blocks every unresolved multi-recipient creation', () {
      for (final count in <int>[2, 3, 16, 256]) {
        expect(
          NewGroupSafetyGate.evaluate(exactRecipientCount: count, existingConversationResolved: false),
          NewConversationExecutionDisposition.newGroupBlockedUnprovenSenderBinding,
        );
      }
    });

    test('rejects invalid cardinality instead of guessing', () {
      expect(
        () => NewGroupSafetyGate.evaluate(exactRecipientCount: -1, existingConversationResolved: false),
        throwsArgumentError,
      );
    });
  });
}
