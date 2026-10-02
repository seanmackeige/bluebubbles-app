import 'package:bluebubbles/app/layouts/conversation_details/widgets/attachments_loader.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/documents/documents_search_helper.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/sections/links/links_section.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_models.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_query_helper.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical search provenance', () {
    test('result keeps physical provenance separate from presentation identity', () {
      final presentation = Chat(guid: 'presentation-guid');
      final source = Chat(guid: 'source-guid');
      final message = Message(guid: 'message-guid');

      final result = SearchResultItem(presentationChat: presentation, sourceChat: source, message: message);

      expect(result.presentationChat, same(presentation));
      expect(result.sourceChat, same(source));
      expect(result.message, same(message));
    });

    test('old-server search issues one stable query per unique certified source GUID', () {
      final guids = SearchQueryHelper.legacyCompatibleSourceQueryGuids(['source-a', 'source-b', 'source-a']);

      expect(guids, ['source-a', 'source-b']);
    });

    test('equal-time results are deterministic across source response order', () {
      final presentation = Chat(guid: 'presentation');
      final sourceA = Chat(guid: 'source-a');
      final sourceB = Chat(guid: 'source-b');
      final created = DateTime.fromMillisecondsSinceEpoch(1000);
      final messageA = Message(guid: 'message-a', dateCreated: created)..chat.target = sourceA;
      final messageB = Message(guid: 'message-b', dateCreated: created)..chat.target = sourceB;
      final first = <SearchResultItem>[
        SearchResultItem(presentationChat: presentation, sourceChat: sourceB, message: messageB),
        SearchResultItem(presentationChat: presentation, sourceChat: sourceA, message: messageA),
      ]..sort(compareLogicalSearchResultsDescending);
      final second = first.reversed.toList()..sort(compareLogicalSearchResultsDescending);

      expect(first.map((item) => item.message.guid), <String?>['message-a', 'message-b']);
      expect(second.map((item) => item.message.guid), first.map((item) => item.message.guid));
    });

    test('canonical window is permutation-invariant across an equal-time cutoff', () {
      final presentation = Chat(guid: 'presentation');
      final source = Chat(guid: 'source');
      final created = DateTime.fromMillisecondsSinceEpoch(1000);
      final items = <SearchResultItem>[
        for (var i = 0; i < 60; i++)
          SearchResultItem(
            presentationChat: presentation,
            sourceChat: source,
            message: Message(guid: 'message-${i.toString().padLeft(2, '0')}', dateCreated: created)
              ..chat.target = source,
          ),
      ];

      final forward = SearchQueryHelper.canonicalResultWindow(items);
      final reverse = SearchQueryHelper.canonicalResultWindow(items.reversed);

      expect(forward, hasLength(50));
      expect(reverse.map((item) => item.message.guid), forward.map((item) => item.message.guid));
      expect(forward.first.message.guid, 'message-00');
      expect(forward.last.message.guid, 'message-49');
    });

    test('duplicates collapse only by exact source and message identity', () {
      final presentation = Chat(guid: 'presentation');
      final sourceA = Chat(guid: 'source-a');
      final sourceB = Chat(guid: 'source-b');
      SearchResultItem item(Chat source) => SearchResultItem(
        presentationChat: presentation,
        sourceChat: source,
        message: Message(guid: 'same-message', dateCreated: DateTime.fromMillisecondsSinceEpoch(1000))
          ..chat.target = source,
      );

      final results = SearchQueryHelper.canonicalResultWindow(<SearchResultItem>[
        item(sourceA),
        item(sourceA),
        item(sourceB),
      ]);

      expect(results.map((result) => result.sourceChat.guid), <String>['source-a', 'source-b']);
    });
  });

  group('logical details exact-identity deduplication', () {
    test('attachments dedupe only an exact source, message, and attachment tuple', () {
      final sourceA = Chat(guid: 'source-a');
      final sourceB = Chat(guid: 'source-b');
      final firstMessage = Message(guid: 'message-a')..chat.target = sourceA;
      final secondMessage = Message(guid: 'message-b')..chat.target = sourceA;
      final collidingMessage = Message(guid: 'message-a')..chat.target = sourceB;
      final first = Attachment(guid: 'attachment-a')..message.target = firstMessage;
      final exactDuplicate = Attachment(guid: 'attachment-a')..message.target = firstMessage;
      final sameAttachmentDifferentMessage = Attachment(guid: 'attachment-a')..message.target = secondMessage;
      final sameIdsDifferentSource = Attachment(guid: 'attachment-a')..message.target = collidingMessage;
      final differentAttachment = Attachment(guid: 'attachment-b')..message.target = firstMessage;

      final deduplicated = dedupeAttachmentsByExactIdentity([
        first,
        exactDuplicate,
        sameAttachmentDifferentMessage,
        sameIdsDifferentSource,
        differentAttachment,
      ]);

      expect(deduplicated, [first, sameAttachmentDifferentMessage, sameIdsDifferentSource, differentAttachment]);
    });

    test('equal-time attachments have stable message and attachment identity order', () {
      final source = Chat(guid: 'source');
      final created = DateTime.fromMillisecondsSinceEpoch(1000);
      final messageA = Message(guid: 'message-a', dateCreated: created)..chat.target = source;
      final messageB = Message(guid: 'message-b', dateCreated: created)..chat.target = source;
      final attachmentA = Attachment(guid: 'attachment-z')..message.target = messageA;
      final attachmentB = Attachment(guid: 'attachment-a')..message.target = messageB;
      final first = <Attachment>[attachmentB, attachmentA]..sort(compareLogicalAttachmentsDescending);
      final second = first.reversed.toList()..sort(compareLogicalAttachmentsDescending);

      expect(first.map((item) => item.message.target?.guid), <String?>['message-a', 'message-b']);
      expect(
        second.map((item) => '${item.message.target?.guid}:${item.guid}'),
        first.map((item) => '${item.message.target?.guid}:${item.guid}'),
      );
    });

    test('equal-score document search retains canonical exact-provenance ordering', () {
      final sourceA = Chat(guid: 'source-a');
      final sourceB = Chat(guid: 'source-b');
      final created = DateTime.fromMillisecondsSinceEpoch(1000);
      final messageA = Message(guid: 'same-message', dateCreated: created)..chat.target = sourceA;
      final messageB = Message(guid: 'same-message', dateCreated: created)..chat.target = sourceB;
      final attachmentA = Attachment(guid: 'attachment-a', transferName: 'report.pdf')..message.target = messageA;
      final attachmentB = Attachment(guid: 'attachment-b', transferName: 'report.pdf')..message.target = messageB;

      final forward = filterAndSortFiles(<Attachment>[attachmentB, attachmentA], 'report');
      final reverse = filterAndSortFiles(<Attachment>[attachmentA, attachmentB], 'report');

      expect(forward.map((item) => item.message.target?.chat.target?.guid), <String?>['source-a', 'source-b']);
      expect(reverse.map((item) => item.guid), forward.map((item) => item.guid));
    });

    test('messages dedupe by exact source and message identity', () {
      final sourceA = Chat(guid: 'source-a');
      final sourceB = Chat(guid: 'source-b');
      final first = Message(guid: 'message-a', text: 'same link')..chat.target = sourceA;
      final exactDuplicate = Message(guid: 'message-a', text: 'same link')..chat.target = sourceA;
      final collidingOtherSource = Message(guid: 'message-a', text: 'same link')..chat.target = sourceB;
      final unrelated = Message(guid: 'message-b', text: 'same link')..chat.target = sourceA;
      final unkeyedOne = Message(text: 'same link');
      final unkeyedTwo = Message(text: 'same link');

      final deduplicated = dedupeLinkMessagesByExactIdentity([
        first,
        exactDuplicate,
        collidingOtherSource,
        unrelated,
        unkeyedOne,
        unkeyedTwo,
      ]);

      expect(deduplicated, [first, collidingOtherSource, unrelated, unkeyedOne, unkeyedTwo]);
    });

    test('equal-time links use canonical message identity ordering', () {
      final source = Chat(guid: 'source');
      final created = DateTime.fromMillisecondsSinceEpoch(1000);
      final first = Message(guid: 'message-b', dateCreated: created)..chat.target = source;
      final second = Message(guid: 'message-a', dateCreated: created)..chat.target = source;
      final forward = <Message>[first, second]..sort(compareLogicalLinkMessagesDescending);
      final reverse = <Message>[second, first]..sort(compareLogicalLinkMessagesDescending);

      expect(forward.map((message) => message.guid), <String?>['message-a', 'message-b']);
      expect(reverse.map((message) => message.guid), forward.map((message) => message.guid));
    });

    test('colliding link identity uses exact physical source as final tie-break', () {
      final sourceA = Chat(guid: 'source-a');
      final sourceB = Chat(guid: 'source-b');
      final created = DateTime.fromMillisecondsSinceEpoch(1000);
      final fromB = Message(guid: 'same-message', dateCreated: created)..chat.target = sourceB;
      final fromA = Message(guid: 'same-message', dateCreated: created)..chat.target = sourceA;
      final ordered = <Message>[fromB, fromA]..sort(compareLogicalLinkMessagesDescending);

      expect(ordered.map((message) => message.chat.target?.guid), <String?>['source-a', 'source-b']);
    });
  });
}
