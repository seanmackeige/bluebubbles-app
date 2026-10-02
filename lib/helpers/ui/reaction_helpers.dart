import 'package:bluebubbles/database/models.dart' hide Entity;
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';
import 'package:flutter/foundation.dart';

class ReactionTypes {
  // ignore: non_constant_identifier_names
  static const String LOVE = "love";
  // ignore: non_constant_identifier_names
  static const String LIKE = "like";
  // ignore: non_constant_identifier_names
  static const String DISLIKE = "dislike";
  // ignore: non_constant_identifier_names
  static const String LAUGH = "laugh";
  // ignore: non_constant_identifier_names
  static const String EMPHASIZE = "emphasize";
  // ignore: non_constant_identifier_names
  static const String QUESTION = "question";

  static List<String> toList() {
    return [LOVE, LIKE, DISLIKE, LAUGH, EMPHASIZE, QUESTION];
  }

  static final Map<String, String> reactionToVerb = {
    LOVE: "loved",
    LIKE: "liked",
    DISLIKE: "disliked",
    LAUGH: "laughed at",
    EMPHASIZE: "emphasized",
    QUESTION: "questioned",
    "-$LOVE": "removed a heart from",
    "-$LIKE": "removed a like from",
    "-$DISLIKE": "removed a dislike from",
    "-$LAUGH": "removed a laugh from",
    "-$EMPHASIZE": "removed an exclamation from",
    "-$QUESTION": "removed a question mark from",
  };

  static final Map<String, String> reactionToEmoji = {
    LOVE: "❤️",
    LIKE: "👍",
    DISLIKE: "👎",
    LAUGH: "😂",
    EMPHASIZE: "❗",
    QUESTION: "❓",
  };

  static final Map<String, String> emojiToReaction = {
    "❤️": LOVE,
    "👍": LIKE,
    "👎": DISLIKE,
    "😂": LAUGH,
    "❗": EMPHASIZE,
    "❓": QUESTION,
  };
}

List<Message> getUniqueReactionMessages(List<Message> messages, {bool logical = false}) {
  List<int> handleCache = [];
  List<Message> output = [];
  // Exact GUID duplicates are one provider event. Content is never a dedupe
  // key. Then put the latest event first using the conversation's chronology.
  final byGuid = <String, Message>{};
  final unkeyed = <Message>[];
  for (final message in messages) {
    final guid = message.guid;
    if (guid == null || guid.isEmpty) {
      unkeyed.add(message);
    } else {
      byGuid.putIfAbsent(guid, () => message);
    }
  }
  final ordered = <Message>[...byGuid.values, ...unkeyed]
    ..sort((left, right) => compareApplicationMessagesDescending(left, right, logical: logical));
  // Iterate over the messages and insert the latest reaction for each user
  for (Message msg in ordered) {
    int cache = msg.isFromMe! ? 0 : msg.handleId ?? 0;
    if (!handleCache.contains(cache) && !kIsWeb) {
      handleCache.add(cache);
      // Only add the reaction if it's not a "negative"
      if (!msg.associatedMessageType!.startsWith("-")) {
        output.add(msg);
      }
    } else if (kIsWeb && !msg.associatedMessageType!.startsWith("-")) {
      output.add(msg);
    }
  }

  return output;
}
