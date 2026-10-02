import 'package:bluebubbles/services/backend/typing_indicator_routing.dart';
import 'package:bluebubbles/services/network/attachment_download_priority.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const canonicalKeys = <String, String>{
    'physical-source-a': 'logical-conversation',
    'physical-source-b': 'logical-conversation',
    'unrelated-source': 'ordinary-conversation',
  };

  String canonicalize(String physicalGuid) => canonicalKeys[physicalGuid] ?? physicalGuid;

  group('attachment download activity', () {
    test('a queued sibling source is active through the canonical conversation key', () {
      final selected = selectActiveAttachmentSourceGuid(
        physicalSourceGuids: const <String>['unrelated-source', 'physical-source-b'],
        activeConversationKey: 'logical-conversation',
        conversationKeyForGuid: canonicalize,
      );

      expect(selected, 'physical-source-b');
    });

    test('selection returns exact physical provenance and never a logical key', () {
      final selected = selectActiveAttachmentSourceGuid(
        physicalSourceGuids: const <String>['physical-source-a', 'physical-source-b'],
        activeConversationKey: 'logical-conversation',
        conversationKeyForGuid: canonicalize,
      );

      expect(selected, 'physical-source-a');
      expect(selected, isNot('logical-conversation'));
    });

    test('missing active conversation or canonical mismatch has no priority target', () {
      expect(
        selectActiveAttachmentSourceGuid(
          physicalSourceGuids: const <String>['physical-source-a'],
          activeConversationKey: null,
          conversationKeyForGuid: canonicalize,
        ),
        isNull,
      );
      expect(
        selectActiveAttachmentSourceGuid(
          physicalSourceGuids: const <String>['unrelated-source'],
          activeConversationKey: 'logical-conversation',
          conversationKeyForGuid: canonicalize,
        ),
        isNull,
      );
    });
  });

  group('typing indicator routing', () {
    test('sibling physical events resolve to one logical controller key', () {
      final first = incomingTypingConversationKey(
        sourceChatGuid: 'physical-source-a',
        conversationKeyForGuid: canonicalize,
      );
      final second = incomingTypingConversationKey(
        sourceChatGuid: 'physical-source-b',
        conversationKeyForGuid: canonicalize,
      );

      expect(first, 'logical-conversation');
      expect(second, first);
    });

    test('ordinary incoming event retains its canonical singleton key', () {
      expect(
        incomingTypingConversationKey(sourceChatGuid: 'unrelated-source', conversationKeyForGuid: canonicalize),
        'ordinary-conversation',
      );
    });

    test('malformed incoming events and logical outbound typing fail closed', () {
      expect(incomingTypingConversationKey(sourceChatGuid: null, conversationKeyForGuid: canonicalize), isNull);
      expect(incomingTypingConversationKey(sourceChatGuid: '', conversationKeyForGuid: canonicalize), isNull);
      expect(canDispatchOutboundTyping(isProtectedLogicalSource: true), isFalse);
      expect(canDispatchOutboundTyping(isProtectedLogicalSource: false), isTrue);
    });
  });
}
