import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:flutter_test/flutter_test.dart';

const _attachment = LogicalAttachmentIntent(
  intentId: 'preview-attachment',
  name: 'preview.png',
  size: 2048,
  isRestorable: true,
  path: '/staged/preview.png',
  mimeType: 'image/png',
);

LogicalDraft _draft({String text = '', List<LogicalAttachmentIntent> attachments = const []}) {
  return LogicalDraft.create(logicalId: 'certified-human-conversation', nowEpochMilliseconds: 1000).mergeUserIntent(
    text: text,
    subject: '',
    attachments: attachments,
    reply: null,
    effectId: null,
    updatedAtEpochMilliseconds: 1100,
  );
}

void main() {
  group('logical conversation-list draft preview', () {
    test('text wins while attachment presence remains projected', () {
      final preview = LogicalDraftPreview.fromDraft(_draft(text: 'Durable logical draft', attachments: [_attachment]));

      expect(preview?.body, 'Durable logical draft');
      expect(preview?.attachmentCount, 1);
      expect(preview?.hasAttachments, isTrue);
    });

    test('attachment-only draft uses the existing bounded label', () {
      final preview = LogicalDraftPreview.fromDraft(_draft(attachments: [_attachment]));

      expect(preview?.body, 'Attachment');
      expect(preview?.attachmentCount, 1);
    });

    test('ordinary ChatState values retain historical preview semantics', () {
      expect(LogicalDraftPreview.fromValues(text: 'Ordinary draft', attachmentCount: 2)?.body, 'Ordinary draft');
      expect(LogicalDraftPreview.fromValues(text: '', attachmentCount: 2)?.body, 'Attachment');
      expect(LogicalDraftPreview.fromValues(text: '', attachmentCount: 0), isNull);
    });

    test('empty logical intent does not hide the latest-message preview', () {
      expect(LogicalDraftPreview.fromDraft(_draft()), isNull);
    });

    test('rearm and JSON restart preserve identical presentation', () {
      final original = _draft(text: 'Survives restart', attachments: [_attachment]);
      final rearmed = original.rearm(
        const LogicalAuthorityRevision(
          certificateRevision: 'certificate-v2',
          authorityRevision: 'authority-v2',
          epoch: 2,
        ),
        updatedAtEpochMilliseconds: 1200,
      );
      final restored = LogicalDraft.fromJson((jsonDecode(jsonEncode(rearmed.toJson())) as Map).cast<String, dynamic>());

      expect(LogicalDraftPreview.fromDraft(rearmed)?.body, 'Survives restart');
      expect(LogicalDraftPreview.fromDraft(restored)?.body, 'Survives restart');
      expect(LogicalDraftPreview.fromDraft(restored)?.attachmentCount, 1);
    });

    test('impossible attachment counts fail closed', () {
      expect(() => LogicalDraftPreview.fromValues(text: '', attachmentCount: -1), throwsArgumentError);
    });
  });
}
