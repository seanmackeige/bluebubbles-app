import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const reply = LogicalReplyIntent(
    messageGuid: 'message-guid',
    relationshipTargetGuid: 'target-guid',
    sourceChatRowId: 42,
    sourceChatGuid: 'source-guid',
    part: 0,
  );

  test('unresolved durable reply can never execute invisibly', () {
    expect(logicalReplyExecutionReady(intent: reply, exactTargetVisible: false), isFalse);
    expect(logicalReplyExecutionReady(intent: reply, exactTargetVisible: true), isTrue);
    expect(logicalReplyExecutionReady(intent: null, exactTargetVisible: false), isTrue);
  });

  test('unresolved reply intent survives deterministic draft restart', () {
    final draft = LogicalDraft.create(logicalId: 'LGC_V1_fixture', nowEpochMilliseconds: 1).mergeUserIntent(
      text: 'human draft',
      subject: '',
      attachments: const <LogicalAttachmentIntent>[],
      reply: reply,
      effectId: null,
      updatedAtEpochMilliseconds: 2,
    );
    final restored = LogicalDraft.fromJson(draft.toJson());
    expect(restored.text, 'human draft');
    expect(restored.reply?.messageGuid, reply.messageGuid);
    expect(logicalReplyExecutionReady(intent: restored.reply, exactTargetVisible: false), isFalse);
  });
}
