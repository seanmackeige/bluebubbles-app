import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';

import 'search_models.dart';
import 'search_source_provenance.dart';

class SearchQueryHelper {
  static String? _exactResultIdentity(SearchResultItem item) {
    final sourceGuid = item.sourceChat.guid;
    if (sourceGuid.isEmpty) return null;
    final messageGuid = item.message.guid;
    if (messageGuid != null && messageGuid.isNotEmpty) {
      return '$sourceGuid\u0000guid:$messageGuid';
    }
    final originalRowId = item.message.originalROWID;
    if (originalRowId != null) {
      return '$sourceGuid\u0000row:$originalRowId';
    }
    return null;
  }

  /// Exact provenance deduplication and deterministic application ordering.
  /// Unkeyed results are retained; message content is never a dedupe key.
  static List<SearchResultItem> canonicalResultWindow(Iterable<SearchResultItem> source, {int limit = 50}) {
    final seen = <String>{};
    final items = <SearchResultItem>[];
    for (final item in source) {
      final identity = _exactResultIdentity(item);
      if (identity == null || seen.add(identity)) items.add(item);
    }
    items.sort(compareLogicalSearchResultsDescending);
    return items.take(limit).toList(growable: false);
  }

  static List<Chat> _sourceChats(Chat chat) {
    final byGuid = <String, Chat>{};
    for (final source in ChatsSvc.logicalSourceChatsFor(chat)) {
      byGuid.putIfAbsent(source.guid, () => source);
    }
    return byGuid.values.toList(growable: false);
  }

  static bool _admitsSource(Chat source) => admitsLogicalSearchSource(
    isPotentialLogicalSource: ChatsSvc.isPotentialLogicalSource(source),
    isApprovedLogicalSource: ChatsSvc.isApprovedLogicalSource(source),
    candidatePhase: ChatsSvc.logicalCandidateQuarantinePhaseFor(source),
  );

  /// Preserve stable source order while issuing only the legacy `chatGuid`
  /// query primitive supported by Sean's Server 1.9.7.
  static List<String> legacyCompatibleSourceQueryGuids(Iterable<String> sourceChatGuids) =>
      sourceChatGuids.toSet().toList(growable: false);

  static Future<List<SearchResultItem>> runLocal({
    required String term,
    required Chat? selectedChat,
    required Handle? selectedHandle,
    required bool isFromMe,
    required bool isNotFromMe,
    required DateTime? sinceDate,
  }) async {
    Condition<Message> condition = Message_.text
        .contains(term, caseSensitive: false)
        .and(Message_.associatedMessageGuid.isNull())
        .and(Message_.dateDeleted.isNull())
        .and(Message_.dateCreated.notNull());

    if (isFromMe) {
      condition = condition.and(Message_.isFromMe.equals(true));
    } else if (isNotFromMe) {
      condition = condition.and(Message_.isFromMe.equals(false));
    } else if (selectedHandle != null) {
      condition = condition.and(Message_.handleId.equals(selectedHandle.originalROWID!));
    }

    if (sinceDate != null) {
      condition = condition.and(Message_.dateCreated.greaterOrEqual(sinceDate.millisecondsSinceEpoch));
    }

    final sourceGuids = selectedChat == null
        ? null
        : _sourceChats(selectedChat).map((chat) => chat.guid).toList(growable: false);
    if (sourceGuids != null && sourceGuids.isEmpty) return [];

    List<Message> findMessages(Condition<Message> queryCondition, {int? limit}) {
      var queryBuilder = Database.messages.query(queryCondition);
      if (sourceGuids != null) {
        queryBuilder = queryBuilder..link(Message_.chat, Chat_.guid.oneOf(sourceGuids));
      }
      final query = queryBuilder.order(Message_.dateCreated, flags: Order.descending).build();
      if (limit != null) query.limit = limit;
      final found = query.find();
      query.close();
      return found;
    }

    var results = findMessages(condition, limit: 50);
    if (results.length == 50) {
      final boundary = results.last.dateCreated;
      if (boundary != null) {
        // ObjectBox cannot express the application GUID/source tie-break in
        // this query. Refetch every boundary tie before the deterministic
        // application window is selected; otherwise insertion order chooses
        // which equal-time messages survive the limit.
        results = findMessages(condition.and(Message_.dateCreated.greaterOrEqual(boundary.millisecondsSinceEpoch)));
      }
    }

    final messages = results.map((e) {
      e.realAttachments;
      e.fetchAssociatedMessages();
      return e;
    }).toList();
    final items = <SearchResultItem>[];
    results.forEachIndexed((index, result) {
      final sourceChat = result.chat.target;
      if (sourceChat == null) return;
      if (!_admitsSource(sourceChat)) return;
      items.add(
        SearchResultItem(
          presentationChat: ChatsSvc.presentationChatFor(sourceChat),
          sourceChat: sourceChat,
          message: messages[index],
        ),
      );
    });
    return canonicalResultWindow(items);
  }

  static Future<List<SearchResultItem>> runNetwork({
    required String term,
    required Chat? selectedChat,
    required Handle? selectedHandle,
    required bool isFromMe,
    required bool isNotFromMe,
    required DateTime? sinceDate,
  }) async {
    final whereClause = <Map<String, dynamic>>[
      {
        'statement': 'message.text LIKE :term COLLATE NOCASE',
        'args': {'term': "%$term%"},
      },
      {'statement': 'message.associated_message_guid IS NULL', 'args': null},
    ];

    final selectedSourceChats = selectedChat == null ? const <Chat>[] : _sourceChats(selectedChat);
    if (selectedChat != null && selectedSourceChats.isEmpty) return [];

    if (isFromMe) {
      whereClause.add({
        'statement': 'message.is_from_me = :isFromMe',
        'args': {'isFromMe': 1},
      });
    } else if (isNotFromMe) {
      whereClause.add({
        'statement': 'message.is_from_me = :isFromMe',
        'args': {'isFromMe': 0},
      });
    } else if (selectedHandle != null) {
      whereClause.add({
        'statement': 'handle.id = :addr',
        'args': {'addr': selectedHandle.address},
      });
    }

    Future<List<NetworkSearchResponseEnvelope>> fetchSource(String? sourceGuid) async {
      final response = await MessagesService.getMessages(
        limit: 50,
        after: sinceDate?.millisecondsSinceEpoch,
        withChats: true,
        withHandles: true,
        withAttachments: true,
        withChatParticipants: true,
        where: whereClause,
        chatGuid: sourceGuid,
      );
      return envelopeNetworkSearchResponse(response, requestedSourceGuid: sourceGuid);
    }

    final results = <NetworkSearchResponseEnvelope>[];
    if (selectedChat == null) {
      results.addAll(await fetchSource(null));
    } else {
      final sourceGuids = legacyCompatibleSourceQueryGuids(selectedSourceChats.map((chat) => chat.guid));
      const maxConcurrentLegacyQueries = 4;
      for (var offset = 0; offset < sourceGuids.length; offset += maxConcurrentLegacyQueries) {
        final end = (offset + maxConcurrentLegacyQueries).clamp(0, sourceGuids.length);
        final batch = sourceGuids.sublist(offset, end);
        final responses = await Future.wait(batch.map(fetchSource));
        for (final response in responses) {
          results.addAll(response);
        }
      }
    }

    final itemChats = <Chat>[];
    final itemMessages = <Message>[];
    for (final envelope in results) {
      final exactSourceChat = exactNetworkSearchSourceChatMap(envelope);
      if (exactSourceChat == null) continue;
      itemChats.add(Chat.fromMap(exactSourceChat));
      itemMessages.add(Message.fromMap(envelope.message));
    }

    final chatGuids = itemChats.map((e) => e.guid).toSet().toList(growable: false);
    final dbChats = <Chat>[];
    if (chatGuids.isNotEmpty) {
      final dbQuery = Database.chats.query(Chat_.guid.oneOf(chatGuids)).build();
      dbChats.addAll(dbQuery.find());
      dbQuery.close();
    }
    final selectedSourcesByGuid = {for (final source in selectedSourceChats) source.guid: source};

    final items = <SearchResultItem>[];
    for (int i = 0; i < itemChats.length; i++) {
      final sourceChat =
          ChatsSvc.findChatByGuid(itemChats[i].guid) ??
          dbChats.firstWhereOrNull((e) => e.guid == itemChats[i].guid) ??
          selectedSourcesByGuid[itemChats[i].guid] ??
          itemChats[i];
      if (!_admitsSource(sourceChat)) continue;
      final message = itemMessages[i]..chat.target = sourceChat;
      items.add(
        SearchResultItem(
          presentationChat: ChatsSvc.presentationChatFor(sourceChat),
          sourceChat: sourceChat,
          message: message,
        ),
      );
    }
    return canonicalResultWindow(items);
  }
}
