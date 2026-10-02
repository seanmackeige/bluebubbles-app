import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';

enum SearchMode { local, network }

class SearchResultItem {
  /// The one logical chat the result must be presented and opened through.
  final Chat presentationChat;

  /// The exact physical chat that supplied [message]. This is provenance only;
  /// it must never be used as the navigation or write-route identity.
  final Chat sourceChat;
  final Message message;

  const SearchResultItem({required this.presentationChat, required this.sourceChat, required this.message});
}

int compareLogicalSearchResultsDescending(SearchResultItem left, SearchResultItem right) {
  final byMessage = compareLogicalMessagesDescending(left.message, right.message);
  if (byMessage != 0) return byMessage;
  return left.sourceChat.guid.compareTo(right.sourceChat.guid);
}
