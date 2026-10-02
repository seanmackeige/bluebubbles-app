import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/ui/reaction_helpers.dart';
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';
import 'package:flutter_test/flutter_test.dart';

Message _message({required String guid, required int created, int? delivered, int? rowId}) => Message(
  guid: guid,
  originalROWID: rowId,
  dateCreated: DateTime.fromMillisecondsSinceEpoch(created),
  dateDelivered: delivered == null ? null : DateTime.fromMillisecondsSinceEpoch(delivered),
  isFromMe: false,
);

void main() {
  test('delivery skew cannot reorder logical chronology', () {
    final newer = _message(guid: 'newer', created: 200, delivered: 100);
    final older = _message(guid: 'older', created: 150);
    final messages = <Message>[older, newer]..sort(compareLogicalMessagesDescending);
    expect(messages, <Message>[newer, older]);
    expect(Message.sort(newer, older), greaterThan(0), reason: 'negative control proves legacy order differs');
  });

  test('equal creation timestamps use GUID then row provenance deterministically', () {
    final b = _message(guid: 'b', created: 100, rowId: 3);
    final a2 = _message(guid: 'a', created: 100, rowId: 2);
    final a1 = _message(guid: 'a', created: 100, rowId: 1);
    final messages = <Message>[b, a2, a1]..sort(compareLogicalMessagesDescending);
    expect(messages, <Message>[a1, a2, b]);
  });

  test('physical member permutations choose the same logical head and recent action target', () {
    final messages = <Message>[
      _message(guid: 'c', created: 300),
      _message(guid: 'a', created: 300),
      _message(guid: 'old', created: 10),
    ];
    for (final permutation in <List<Message>>[
      messages,
      messages.reversed.toList(),
      <Message>[messages[1], messages[2], messages[0]],
    ]) {
      final ordered = permutation.toList()..sort(compareLogicalMessagesDescending);
      expect(ordered.first.guid, 'a');
      expect(mostRecentApplicationMessage(permutation, logical: true)?.guid, 'a');
    }
  });

  test('logical thread and forward order reverses visible chronology while ordinary keeps legacy order', () {
    final created = DateTime.fromMillisecondsSinceEpoch(1000);
    final a = Message(guid: 'message-a', dateCreated: created);
    final b = Message(guid: 'message-b', dateCreated: created);
    final logical = <Message>[a, b]
      ..sort((left, right) => compareApplicationMessagesAscending(left, right, logical: true));
    expect(logical.map((message) => message.guid), <String?>['message-b', 'message-a']);

    final old = Message(guid: 'old', dateCreated: DateTime.fromMillisecondsSinceEpoch(1));
    final newer = Message(guid: 'new', dateCreated: DateTime.fromMillisecondsSinceEpoch(2));
    final ordinary = <Message>[newer, old]
      ..sort((left, right) => compareApplicationMessagesAscending(left, right, logical: false));
    expect(ordinary.map((message) => message.guid), <String?>['old', 'new']);
  });

  test('logical previous reply follows canonical chronology across equal-time permutations', () {
    ChatMessages build(List<Message> replies) {
      final struct = ChatMessages();
      struct.addMessages(<Message>[
        Message(guid: 'thread', dateCreated: DateTime.fromMillisecondsSinceEpoch(1), isFromMe: false),
        ...replies,
      ]);
      return struct;
    }

    Message reply(String guid) => Message(
      guid: guid,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(1000),
      isFromMe: false,
      threadOriginatorGuid: 'thread',
      threadOriginatorPart: '0',
    );

    final a = reply('message-a');
    final b = reply('message-b');
    expect(build(<Message>[a, b]).getPreviousReply('thread', 0, 'message-a', logical: true)?.guid, 'message-b');
    expect(build(<Message>[b, a]).getPreviousReply('thread', 0, 'message-a', logical: true)?.guid, 'message-b');
  });

  test('logical reaction winner uses creation chronology rather than delivery skew', () {
    Message reaction({required String guid, required String type, required int created, int? delivered}) => Message(
      guid: guid,
      dateCreated: DateTime.fromMillisecondsSinceEpoch(created),
      dateDelivered: delivered == null ? null : DateTime.fromMillisecondsSinceEpoch(delivered),
      isFromMe: false,
      handleId: 7,
      associatedMessageGuid: 'target',
      associatedMessageType: type,
    );

    final newer = reaction(guid: 'newer', type: ReactionTypes.LOVE, created: 200, delivered: 50);
    final older = reaction(guid: 'older', type: ReactionTypes.LIKE, created: 100);

    for (final input in <List<Message>>[
      <Message>[older, newer],
      <Message>[newer, older],
    ]) {
      expect(getUniqueReactionMessages(input, logical: true).single.guid, 'newer');
    }
    expect(
      getUniqueReactionMessages(<Message>[older, newer], logical: false).single.guid,
      'older',
      reason: 'ordinary chats retain their legacy delivery-aware reaction ordering',
    );
  });
}
