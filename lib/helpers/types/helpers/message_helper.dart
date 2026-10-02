import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

const String _darkSunglassesEmoji = '\u{1F576}';
const int _maxBigEmojiGraphemeCodeUnits = 64;
const int _maxBigEmojiCandidateCodeUnits = 3 * _maxBigEmojiGraphemeCodeUnits;
const int _maxBigEmojiRawCodeUnits = _maxBigEmojiCandidateCodeUnits + 64;
const int _maxEmojiStyledTextCodeUnits = 4096;
final RegExp _renderEmojiRegex = RegExp("${emojiRegex.pattern}|$_darkSunglassesEmoji");

class MessageHelper {
  /// Removes duplicate associated message guids from a list of [associatedMessages]
  static List<Message> normalizedAssociatedMessages(List<Message> associatedMessages) {
    Set<String> guids = associatedMessages.map((e) => e.guid!).toSet();
    List<Message> normalized = [];

    for (Message message in associatedMessages.reversed.toList()) {
      if (!ReactionTypes.toList().contains(message.associatedMessageType)) {
        normalized.add(message);
      } else if (guids.remove(message.guid)) {
        normalized.add(message);
      }
    }
    return normalized;
  }

  static bool shouldShowBigEmoji(String text) {
    if (isNullOrEmptyString(text)) return false;
    if (text.length > _maxBigEmojiRawCodeUnits) return false;
    final candidate = text.trim();
    if (candidate.isEmpty || candidate.length > _maxBigEmojiCandidateCodeUnits) return false;

    // A big-emoji bubble contains at most three grapheme clusters. Never feed
    // the complete message to the generated emoji regexp: the exact S24 ANR
    // caught that regexp monopolizing the Dart UI isolate during timeline
    // layout. Each regexp invocation is now capped to one bounded cluster, and
    // ordinary text exits after its first non-emoji cluster.
    var graphemeCount = 0;
    for (final grapheme in candidate.characters) {
      graphemeCount += 1;
      if (graphemeCount > 3 || grapheme.length > _maxBigEmojiGraphemeCodeUnits) return false;

      if (grapheme.codeUnits.length == 1 && grapheme.codeUnits.first == 9786) continue;

      final matches = emojiRegex.allMatches(grapheme).toList(growable: false);
      final hasDarkSunglasses = grapheme.contains(_darkSunglassesEmoji);
      if (matches.isEmpty && !hasDarkSunglasses) return false;

      final remainder = grapheme
          .replaceAll(emojiRegex, "")
          .replaceAll(String.fromCharCode(65039), "")
          .replaceAll(_darkSunglassesEmoji, "");
      if (remainder.isNotEmpty) return false;
    }
    return graphemeCount > 0;
  }

  static List<TextSpan> buildEmojiText(String text, TextStyle style, {TapGestureRecognizer? recognizer}) {
    if (!FilesystemSvc.fontExistsOnDisk.value || text.length > _maxEmojiStyledTextCodeUnits) {
      return [TextSpan(text: text, style: style, recognizer: recognizer)];
    }

    // Keep every invocation of the generated emoji regexp bounded. The
    // big-emoji check is followed immediately by this renderer, so bounding
    // only the classifier would merely move the exact S24 stall to this path.
    final children = <TextSpan>[];
    final chunk = StringBuffer();

    void flushChunk() {
      if (chunk.isEmpty) return;
      _appendEmojiTextChunk(children, chunk.toString(), style, recognizer);
      chunk.clear();
    }

    for (final grapheme in text.characters) {
      if (grapheme.length > _maxBigEmojiGraphemeCodeUnits) {
        flushChunk();
        children.add(TextSpan(text: grapheme, style: style, recognizer: recognizer));
        continue;
      }
      if (chunk.length + grapheme.length > _maxBigEmojiGraphemeCodeUnits) {
        flushChunk();
      }
      chunk.write(grapheme);
    }
    flushChunk();

    return children;
  }

  static void _appendEmojiTextChunk(
    List<TextSpan> children,
    String text,
    TextStyle style,
    TapGestureRecognizer? recognizer,
  ) {
    final matches = _renderEmojiRegex.allMatches(text).toList(growable: false);
    if (matches.isEmpty) {
      children.add(TextSpan(text: text, style: style, recognizer: recognizer));
      return;
    }

    var previousEnd = 0;
    var i = 0;
    while (i < matches.length) {
      final emojiStart = matches[i].start;
      if (previousEnd < emojiStart) {
        children.add(TextSpan(text: text.substring(previousEnd, emojiStart), style: style, recognizer: recognizer));
      }

      var emojiEnd = matches[i].end;
      while (i + 1 < matches.length && matches[i + 1].start == emojiEnd) {
        i += 1;
        emojiEnd = matches[i].end;
      }
      children.add(
        TextSpan(
          text: text.substring(emojiStart, emojiEnd),
          style: style.apply(fontFamily: "Apple Color Emoji"),
          recognizer: recognizer,
        ),
      );
      previousEnd = emojiEnd;
      i += 1;
    }
    if (previousEnd < text.length) {
      children.add(TextSpan(text: text.substring(previousEnd), style: style, recognizer: recognizer));
    }
  }
}
