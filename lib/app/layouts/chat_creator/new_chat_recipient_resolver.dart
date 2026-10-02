import 'dart:collection';

import 'package:bluebubbles/helpers/types/classes/chat_service_type.dart';
import 'package:dlibphonenumber/dlibphonenumber.dart';

enum RecipientServiceAvailability { available, unavailable, unknown }

class NewChatRecipientSelection {
  const NewChatRecipientSelection({required this.address, this.availability = RecipientServiceAvailability.unknown});

  final String address;
  final RecipientServiceAvailability availability;
}

class ExistingConversationRecipientCandidate {
  const ExistingConversationRecipientCandidate({
    required this.conversationId,
    required this.service,
    required this.recipientAddresses,
  });

  final String conversationId;
  final ChatServiceType service;
  final List<String> recipientAddresses;
}

enum NewChatRecipientResolutionDisposition {
  noRecipients,
  invalidRecipient,
  duplicateRecipient,
  unsupportedService,
  exactExistingConversation,
  multipleExactExistingConversations,
  explicitConversationMismatch,
  newOneToOne,
  groupRecipientUnavailable,
  groupServiceMismatch,
  unresolvedGroup,
}

class NewChatRecipientResolution {
  const NewChatRecipientResolution._({
    required this.disposition,
    required this.normalizedRecipients,
    this.exactConversationId,
    this.exactConversationIds = const <String>[],
    this.invalidRecipientIndexes = const <int>[],
  });

  final NewChatRecipientResolutionDisposition disposition;
  final List<String> normalizedRecipients;
  final String? exactConversationId;
  final List<String> exactConversationIds;
  final List<int> invalidRecipientIndexes;

  bool get canReuseExistingConversation =>
      disposition == NewChatRecipientResolutionDisposition.exactExistingConversation && exactConversationId != null;

  bool get canCreateOneToOne => disposition == NewChatRecipientResolutionDisposition.newOneToOne;

  bool get isAdmitted => canReuseExistingConversation || canCreateOneToOne;

  String get blockedTitle {
    switch (disposition) {
      case NewChatRecipientResolutionDisposition.multipleExactExistingConversations:
        return 'Existing matching group requires selection';
      case NewChatRecipientResolutionDisposition.duplicateRecipient:
      case NewChatRecipientResolutionDisposition.invalidRecipient:
      case NewChatRecipientResolutionDisposition.noRecipients:
        return 'Check recipients';
      case NewChatRecipientResolutionDisposition.groupRecipientUnavailable:
        return 'Recipient unavailable for selected service';
      case NewChatRecipientResolutionDisposition.groupServiceMismatch:
        return 'Existing group uses a different service';
      case NewChatRecipientResolutionDisposition.unsupportedService:
      case NewChatRecipientResolutionDisposition.explicitConversationMismatch:
      case NewChatRecipientResolutionDisposition.unresolvedGroup:
        return 'Group creation unavailable';
      case NewChatRecipientResolutionDisposition.exactExistingConversation:
      case NewChatRecipientResolutionDisposition.newOneToOne:
        return '';
    }
  }

  String get blockedExplanation {
    switch (disposition) {
      case NewChatRecipientResolutionDisposition.multipleExactExistingConversations:
        return 'More than one conversation exactly matches these recipients and service. Select the intended conversation explicitly.';
      case NewChatRecipientResolutionDisposition.duplicateRecipient:
        return 'Each normalized recipient must be selected exactly once.';
      case NewChatRecipientResolutionDisposition.invalidRecipient:
        return 'One or more recipient addresses could not be normalized safely.';
      case NewChatRecipientResolutionDisposition.noRecipients:
        return 'Select at least one recipient.';
      case NewChatRecipientResolutionDisposition.groupRecipientUnavailable:
        return 'Every participant must be available for the selected service.';
      case NewChatRecipientResolutionDisposition.groupServiceMismatch:
        return 'A matching recipient set exists only on another service. The service will not be changed automatically.';
      case NewChatRecipientResolutionDisposition.unsupportedService:
        return 'The selected service is not available for this operation.';
      case NewChatRecipientResolutionDisposition.explicitConversationMismatch:
        return 'The selected conversation no longer exactly matches the recipients and service.';
      case NewChatRecipientResolutionDisposition.unresolvedGroup:
        return 'Select an existing exact group or continue with one recipient.';
      case NewChatRecipientResolutionDisposition.exactExistingConversation:
      case NewChatRecipientResolutionDisposition.newOneToOne:
        return '';
    }
  }
}

/// Pure, deterministic admission and existing-conversation resolver.
///
/// Recipient equality is an exact comparison of normalized, unique addresses.
/// No selected address may consume the same physical recipient twice, and a
/// candidate on a different service is never reusable. Multiple exact physical
/// candidates fail closed unless the caller supplies one exact candidate as an
/// explicit user selection.
class NewChatRecipientResolver {
  const NewChatRecipientResolver._();

  static NewChatRecipientResolution resolve({
    required List<NewChatRecipientSelection> recipients,
    required ChatServiceType requestedService,
    required Iterable<ExistingConversationRecipientCandidate> candidates,
    String? explicitlySelectedConversationId,
    String regionCode = 'US',
  }) {
    if (recipients.isEmpty) {
      return const NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.noRecipients,
        normalizedRecipients: <String>[],
      );
    }
    if (requestedService == ChatServiceType.rcs) {
      return const NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.unsupportedService,
        normalizedRecipients: <String>[],
      );
    }

    final normalized = <_NormalizedRecipient>[];
    final invalidIndexes = <int>[];
    for (var index = 0; index < recipients.length; index++) {
      final value = _normalizeAddress(recipients[index].address, regionCode);
      if (value == null || (requestedService == ChatServiceType.sms && value.isEmail)) {
        invalidIndexes.add(index);
      } else {
        normalized.add(value);
      }
    }
    if (invalidIndexes.isNotEmpty) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.invalidRecipient,
        normalizedRecipients: List<String>.unmodifiable(normalized.map((value) => value.key)),
        invalidRecipientIndexes: List<int>.unmodifiable(invalidIndexes),
      );
    }

    final normalizedKeys = normalized.map((value) => value.key).toList()..sort();
    if (normalizedKeys.toSet().length != normalizedKeys.length) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.duplicateRecipient,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
      );
    }

    final exactIds = SplayTreeSet<String>();
    var matchingRecipientsOnAnotherService = false;
    for (final candidate in candidates) {
      if (candidate.conversationId.trim().isEmpty) continue;
      final candidateKeys = _normalizeCandidateRecipients(candidate, requestedService, regionCode);
      if (candidateKeys == null || !_equalSorted(normalizedKeys, candidateKeys)) continue;
      if (candidate.service == requestedService) {
        exactIds.add(candidate.conversationId);
      } else {
        matchingRecipientsOnAnotherService = true;
      }
    }

    final exactConversationIds = List<String>.unmodifiable(exactIds);
    if (explicitlySelectedConversationId != null) {
      if (exactIds.contains(explicitlySelectedConversationId)) {
        return NewChatRecipientResolution._(
          disposition: NewChatRecipientResolutionDisposition.exactExistingConversation,
          normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
          exactConversationId: explicitlySelectedConversationId,
          exactConversationIds: exactConversationIds,
        );
      }
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.explicitConversationMismatch,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
        exactConversationIds: exactConversationIds,
      );
    }
    if (exactIds.length == 1) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.exactExistingConversation,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
        exactConversationId: exactIds.single,
        exactConversationIds: exactConversationIds,
      );
    }
    if (exactIds.length > 1) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.multipleExactExistingConversations,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
        exactConversationIds: exactConversationIds,
      );
    }

    if (recipients.length == 1) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.newOneToOne,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
      );
    }
    if (recipients.any((recipient) => recipient.availability != RecipientServiceAvailability.available)) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.groupRecipientUnavailable,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
      );
    }
    if (matchingRecipientsOnAnotherService) {
      return NewChatRecipientResolution._(
        disposition: NewChatRecipientResolutionDisposition.groupServiceMismatch,
        normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
      );
    }
    return NewChatRecipientResolution._(
      disposition: NewChatRecipientResolutionDisposition.unresolvedGroup,
      normalizedRecipients: List<String>.unmodifiable(normalizedKeys),
    );
  }

  static List<String>? _normalizeCandidateRecipients(
    ExistingConversationRecipientCandidate candidate,
    ChatServiceType requestedService,
    String regionCode,
  ) {
    final keys = <String>[];
    for (final address in candidate.recipientAddresses) {
      final normalized = _normalizeAddress(address, regionCode);
      if (normalized == null ||
          ((candidate.service == ChatServiceType.sms || requestedService == ChatServiceType.sms) &&
              normalized.isEmail)) {
        return null;
      }
      keys.add(normalized.key);
    }
    keys.sort();
    if (keys.toSet().length != keys.length) return null;
    return keys;
  }

  static _NormalizedRecipient? _normalizeAddress(String rawAddress, String regionCode) {
    final address = rawAddress.trim();
    if (address.isEmpty) return null;

    if (address.contains('@')) {
      final normalized = address.toLowerCase();
      final firstAt = normalized.indexOf('@');
      if (firstAt <= 0 || firstAt != normalized.lastIndexOf('@') || firstAt == normalized.length - 1) {
        return null;
      }
      return _NormalizedRecipient('email:$normalized', isEmail: true);
    }

    if (!RegExp(r'^\+?[0-9().\-\s]+$').hasMatch(address)) return null;
    final digits = address.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty || digits.length > 15) return null;
    try {
      final parsed = PhoneNumberUtil.instance.parse(address, address.startsWith('+') ? null : regionCode);
      if (PhoneNumberUtil.instance.isPossibleNumber(parsed)) {
        final e164 = PhoneNumberUtil.instance.format(parsed, PhoneNumberFormat.e164);
        final canonicalDigits = e164.replaceAll(RegExp(r'\D'), '');
        if (canonicalDigits.isNotEmpty && canonicalDigits.length <= 15) {
          return _NormalizedRecipient('phone:$canonicalDigits', isEmail: false);
        }
      }
    } catch (_) {}
    return _NormalizedRecipient('phone:$digits', isEmail: false);
  }

  static bool _equalSorted(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class _NormalizedRecipient {
  const _NormalizedRecipient(this.key, {required this.isEmail});

  final String key;
  final bool isEmail;
}
