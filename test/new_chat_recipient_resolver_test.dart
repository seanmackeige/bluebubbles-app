import 'package:bluebubbles/app/layouts/chat_creator/new_chat_recipient_resolver.dart';
import 'package:bluebubbles/helpers/types/classes/chat_service_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const available = RecipientServiceAvailability.available;

  NewChatRecipientSelection recipient(String address, {RecipientServiceAvailability availability = available}) {
    return NewChatRecipientSelection(address: address, availability: availability);
  }

  ExistingConversationRecipientCandidate candidate(String id, ChatServiceType service, List<String> addresses) {
    return ExistingConversationRecipientCandidate(conversationId: id, service: service, recipientAddresses: addresses);
  }

  group('NewChatRecipientResolver', () {
    test('duplicate normalized selections fail closed instead of consuming one handle twice', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('+1 (415) 555-0100'), recipient('14155550100')],
        requestedService: ChatServiceType.iMessage,
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('group-ab', ChatServiceType.iMessage, <String>['+1 415 555 0100', '+1 415 555 0101']),
        ],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.duplicateRecipient);
      expect(result.isAdmitted, isFalse);
      expect(result.exactConversationId, isNull);
    });

    test('normalization is exact and order independent', () {
      final recipients = <NewChatRecipientSelection>[
        recipient('  PERSON@Example.COM '),
        recipient('+1 (415) 555-0100'),
      ];
      final forward = NewChatRecipientResolver.resolve(
        recipients: recipients,
        requestedService: ChatServiceType.iMessage,
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('exact', ChatServiceType.iMessage, <String>['14155550100', 'person@example.com']),
        ],
      );
      final reversed = NewChatRecipientResolver.resolve(
        recipients: recipients.reversed.toList(),
        requestedService: ChatServiceType.iMessage,
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('exact', ChatServiceType.iMessage, <String>['person@example.com', '+1 415-555-0100']),
        ],
      );

      expect(forward.disposition, NewChatRecipientResolutionDisposition.exactExistingConversation);
      expect(reversed.disposition, forward.disposition);
      expect(reversed.exactConversationId, forward.exactConversationId);
      expect(reversed.normalizedRecipients, forward.normalizedRecipients);
    });

    test('same recipients on another service are never reused', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('14155550100'), recipient('14155550101')],
        requestedService: ChatServiceType.iMessage,
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('sms-group', ChatServiceType.sms, <String>['14155550100', '14155550101']),
        ],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.groupServiceMismatch);
      expect(result.isAdmitted, isFalse);
    });

    test('unavailable or unresolved participant blocks a new group', () {
      for (final availability in <RecipientServiceAvailability>[
        RecipientServiceAvailability.unavailable,
        RecipientServiceAvailability.unknown,
      ]) {
        final result = NewChatRecipientResolver.resolve(
          recipients: <NewChatRecipientSelection>[
            recipient('14155550100'),
            recipient('14155550101', availability: availability),
          ],
          requestedService: ChatServiceType.iMessage,
          candidates: const <ExistingConversationRecipientCandidate>[],
        );

        expect(result.disposition, NewChatRecipientResolutionDisposition.groupRecipientUnavailable);
        expect(result.isAdmitted, isFalse);
      }
    });

    test('one exact service-and-recipient candidate is reusable', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('a@example.com'), recipient('b@example.com')],
        requestedService: ChatServiceType.iMessage,
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('not-exact', ChatServiceType.iMessage, <String>['a@example.com', 'c@example.com']),
          candidate('exact', ChatServiceType.iMessage, <String>['b@example.com', 'A@EXAMPLE.COM']),
        ],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.exactExistingConversation);
      expect(result.exactConversationId, 'exact');
      expect(result.isAdmitted, isTrue);
    });

    test('multiple historical exact matches require explicit selection', () {
      final candidates = <ExistingConversationRecipientCandidate>[
        candidate('historical-b', ChatServiceType.iMessage, <String>['a@example.com', 'b@example.com']),
        candidate('historical-a', ChatServiceType.iMessage, <String>['b@example.com', 'a@example.com']),
      ];
      final unresolved = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('a@example.com'), recipient('b@example.com')],
        requestedService: ChatServiceType.iMessage,
        candidates: candidates,
      );

      expect(unresolved.disposition, NewChatRecipientResolutionDisposition.multipleExactExistingConversations);
      expect(unresolved.exactConversationIds, <String>['historical-a', 'historical-b']);
      expect(unresolved.isAdmitted, isFalse);

      final selected = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('b@example.com'), recipient('a@example.com')],
        requestedService: ChatServiceType.iMessage,
        candidates: candidates.reversed,
        explicitlySelectedConversationId: 'historical-b',
      );
      expect(selected.disposition, NewChatRecipientResolutionDisposition.exactExistingConversation);
      expect(selected.exactConversationId, 'historical-b');
    });

    test('ordinary normalized one-to-one remains admitted for legacy creation', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[
          recipient('+1 (415) 555-0100', availability: RecipientServiceAvailability.unknown),
        ],
        requestedService: ChatServiceType.iMessage,
        candidates: const <ExistingConversationRecipientCandidate>[],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.newOneToOne);
      expect(result.canCreateOneToOne, isTrue);
    });

    test('national and E.164 forms reuse the same ordinary one-to-one', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('(415) 555-0100')],
        requestedService: ChatServiceType.iMessage,
        regionCode: 'US',
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('existing-one-to-one', ChatServiceType.iMessage, <String>['+1 415 555 0100']),
        ],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.exactExistingConversation);
      expect(result.exactConversationId, 'existing-one-to-one');
      expect(result.normalizedRecipients, <String>['phone:14155550100']);
    });

    test('national and E.164 duplicate group selections fail closed', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('(415) 555-0100'), recipient('+1 415 555 0100')],
        requestedService: ChatServiceType.iMessage,
        regionCode: 'US',
        candidates: const <ExistingConversationRecipientCandidate>[],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.duplicateRecipient);
      expect(result.isAdmitted, isFalse);
    });

    test('region-specific national form canonicalizes without suffix guessing', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('020 7946 0018')],
        requestedService: ChatServiceType.iMessage,
        regionCode: 'GB',
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('gb-existing', ChatServiceType.iMessage, <String>['+44 20 7946 0018']),
        ],
      );
      expect(result.exactConversationId, 'gb-existing');
    });

    test('candidate duplicates are not an exact recipient set', () {
      final result = NewChatRecipientResolver.resolve(
        recipients: <NewChatRecipientSelection>[recipient('a@example.com'), recipient('b@example.com')],
        requestedService: ChatServiceType.iMessage,
        candidates: <ExistingConversationRecipientCandidate>[
          candidate('bad-candidate', ChatServiceType.iMessage, <String>['a@example.com', 'a@example.com']),
        ],
      );

      expect(result.disposition, NewChatRecipientResolutionDisposition.unresolvedGroup);
      expect(result.isAdmitted, isFalse);
    });

    test('candidate and recipient permutation property preserves the decision', () {
      final recipientOrders = <List<NewChatRecipientSelection>>[
        <NewChatRecipientSelection>[recipient('a@example.com'), recipient('b@example.com'), recipient('14155550100')],
        <NewChatRecipientSelection>[recipient('14155550100'), recipient('a@example.com'), recipient('b@example.com')],
        <NewChatRecipientSelection>[recipient('b@example.com'), recipient('14155550100'), recipient('a@example.com')],
      ];
      final participantOrders = <List<String>>[
        <String>['a@example.com', 'b@example.com', '+1 (415) 555-0100'],
        <String>['+1 415 555 0100', 'b@example.com', 'A@EXAMPLE.COM'],
        <String>['b@example.com', '14155550100', 'a@example.com'],
      ];

      for (final selected in recipientOrders) {
        for (final participants in participantOrders) {
          final result = NewChatRecipientResolver.resolve(
            recipients: selected,
            requestedService: ChatServiceType.iMessage,
            candidates: <ExistingConversationRecipientCandidate>[
              candidate('exact', ChatServiceType.iMessage, participants),
            ],
          );
          expect(result.disposition, NewChatRecipientResolutionDisposition.exactExistingConversation);
          expect(result.exactConversationId, 'exact');
        }
      }
    });

    test('invalid addresses and SMS email recipients fail before creation', () {
      for (final input in <({String address, ChatServiceType service})>[
        (address: 'not a recipient', service: ChatServiceType.iMessage),
        (address: 'person@example.com', service: ChatServiceType.sms),
      ]) {
        final result = NewChatRecipientResolver.resolve(
          recipients: <NewChatRecipientSelection>[recipient(input.address)],
          requestedService: input.service,
          candidates: const <ExistingConversationRecipientCandidate>[],
        );
        expect(result.disposition, NewChatRecipientResolutionDisposition.invalidRecipient);
        expect(result.isAdmitted, isFalse);
      }
    });
  });
}
