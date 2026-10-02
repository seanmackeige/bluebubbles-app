import 'package:bluebubbles/app/layouts/chat_creator/new_chat_recipient_resolver.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/utils/string_utils.dart';
import 'package:get/get.dart';

class ChatCreatorUtils {
  static const List<int> _phoneMatchLengths = <int>[15, 14, 13, 12, 11, 10, 9, 8, 7];

  static List<ContactV2> filterContacts(List<ContactV2> contacts, String query) {
    return contacts
        .where(
          (e) =>
              e.computedDisplayName.toLowerCase().contains(query) ||
              (e.nickname?.toLowerCase().contains(query) ?? false) ||
              e.phoneNumbers.firstWhereOrNull((p) => cleansePhoneNumber(p.number.toLowerCase()).contains(query)) !=
                  null ||
              e.emailAddresses.firstWhereOrNull((email) => email.address.toLowerCase().contains(query)) != null,
        )
        .toList();
  }

  static List<Chat> filterChats(List<Chat> chats, String query, ChatServiceType selectedService) {
    return chats
        .where(
          (chat) =>
              (selectedService.isIMessageService == chat.isIMessage) &&
              (chat.getTitle().toLowerCase().contains(query) ||
                  chat.handles.firstWhereOrNull(
                        (handle) => handle.address.contains(query) || handle.displayName.toLowerCase().contains(query),
                      ) !=
                      null),
        )
        .toList();
  }

  static ExistingConversationRecipientCandidate recipientCandidateForChat(Chat chat) {
    final handles = chat.handles.map((handle) => handle.address).toList(growable: false);
    final participants = chat.participants.map((handle) => handle.address).toList(growable: false);
    final addresses = handles.isNotEmpty
        ? handles
        : participants.isNotEmpty
        ? participants
        : <String>[if (chat.chatIdentifier?.trim().isNotEmpty ?? false) chat.chatIdentifier!];
    return ExistingConversationRecipientCandidate(
      conversationId: chat.guid,
      service: chat.service,
      recipientAddresses: addresses,
    );
  }

  static NewChatRecipientResolution resolveRecipientSelection({
    required List<NewChatRecipientSelection> recipients,
    required ChatServiceType requestedService,
    required Iterable<Chat> chats,
    String? explicitlySelectedConversationId,
  }) {
    return NewChatRecipientResolver.resolve(
      recipients: recipients,
      requestedService: requestedService,
      candidates: chats.map(recipientCandidateForChat),
      explicitlySelectedConversationId: explicitlySelectedConversationId,
      regionCode: Get.deviceLocale?.countryCode ?? 'US',
    );
  }

  static RecipientServiceAvailability availabilityForRequestedService({
    required String address,
    required ChatServiceType requestedService,
    required ChatServiceType? observedService,
  }) {
    if (requestedService == ChatServiceType.sms && !address.contains('@')) {
      return RecipientServiceAvailability.available;
    }
    if (observedService == null) return RecipientServiceAvailability.unknown;
    return observedService == requestedService
        ? RecipientServiceAvailability.available
        : RecipientServiceAvailability.unavailable;
  }

  static bool chatMatchesSelectedContacts(Chat chat, List<String> selectedAddresses) {
    if (chat.handles.length != selectedAddresses.length) return false;

    // Maximum bipartite matching: every selected address must consume one
    // distinct physical handle. The old nested-loop counter allowed [A, A]
    // to consume the same A handle twice and falsely match [A, B].
    final handleToSelection = List<int>.filled(chat.handles.length, -1);
    bool matchSelection(int selectionIndex, List<bool> visited) {
      for (var handleIndex = 0; handleIndex < chat.handles.length; handleIndex++) {
        if (visited[handleIndex] ||
            !addressesMatch(selectedAddresses[selectionIndex], chat.handles[handleIndex].address)) {
          continue;
        }
        visited[handleIndex] = true;
        if (handleToSelection[handleIndex] == -1 || matchSelection(handleToSelection[handleIndex], visited)) {
          handleToSelection[handleIndex] = selectionIndex;
          return true;
        }
      }
      return false;
    }

    for (var selectionIndex = 0; selectionIndex < selectedAddresses.length; selectionIndex++) {
      if (!matchSelection(selectionIndex, List<bool>.filled(chat.handles.length, false))) return false;
    }
    return true;
  }

  /// Compares two handle addresses (phone numbers or emails), tolerating
  /// differing phone number formats (country code, punctuation, etc).
  static bool addressesMatch(String a, String b) {
    if (a.isEmail && !b.isEmail) return false;
    if (a == b) return true;

    final numeric = a.numericOnly();
    return _phoneMatchLengths.contains(numeric.length) && cleansePhoneNumber(b).endsWith(numeric);
  }
}
