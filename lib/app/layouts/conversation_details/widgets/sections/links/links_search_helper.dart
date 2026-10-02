import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';

/// Domain text shown on link preview cards (host without leading `www.`).
String linkPreviewDomain(UrlPreviewData data) {
  final raw = Uri.tryParse(data.originalUrl ?? data.url ?? '')?.host ?? data.siteName ?? '';
  return raw.replaceFirst(RegExp(r'^www\.'), '');
}

int _fieldMatchScore(String field, String query, int tierBase) {
  if (field.isEmpty) return 0;
  if (field == query) return tierBase + 30;
  if (field.startsWith(query)) return tierBase + 20;
  if (field.contains(query)) return tierBase + 10;
  return 0;
}

/// Match score for a link preview. Higher is better; `0` means no match.
/// Priority: domain (300) > title (200) > description/summary (100).
int linkPreviewSearchScore(UrlPreviewData data, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return 0;

  final domain = linkPreviewDomain(data).toLowerCase();
  final title = (data.title ?? '').toLowerCase();
  final description = (data.summary ?? '').toLowerCase();

  return [
    _fieldMatchScore(domain, normalizedQuery, 300),
    _fieldMatchScore(title, normalizedQuery, 200),
    _fieldMatchScore(description, normalizedQuery, 100),
  ].reduce((a, b) => a > b ? a : b);
}

/// Filters [messages] to link previews matching [query], ordered by best match then recency.
List<Message> filterAndSortLinks(List<Message> messages, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return messages;

  final scored = <({Message message, int score})>[];
  for (final message in messages) {
    final data = message.payloadData?.urlData?.firstOrNull;
    if (data == null) continue;
    final score = linkPreviewSearchScore(data, normalizedQuery);
    if (score > 0) {
      scored.add((message: message, score: score));
    }
  }

  scored.sort((a, b) {
    final scoreCompare = b.score.compareTo(a.score);
    if (scoreCompare != 0) return scoreCompare;
    return compareLogicalMessagesDescending(a.message, b.message);
  });

  return scored.map((e) => e.message).toList();
}
