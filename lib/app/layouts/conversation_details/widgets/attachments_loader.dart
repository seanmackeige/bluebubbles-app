import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/logical_membership_refresh.dart';
import 'package:bluebubbles/services/ui/chat/logical_message_chronology.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

String? _attachmentIdentity(Attachment attachment) {
  if (attachment.guid != null) return 'guid:${attachment.guid}';
  if (attachment.originalROWID != null) return 'row:${attachment.originalROWID}';
  if (attachment.id != null) return 'local:${attachment.id}';
  return null;
}

String? _messageIdentity(Message? message) {
  if (message?.guid != null) return 'guid:${message!.guid}';
  if (message?.originalROWID != null) return 'row:${message!.originalROWID}';
  if (message?.id != null) return 'local:${message!.id}';
  return null;
}

String? _sourceChatIdentity(Message? message) {
  final chat = message?.chat.target;
  if (chat?.guid != null) return 'guid:${chat!.guid}';
  if (chat?.id != null) return 'local:${chat!.id}';
  return null;
}

@visibleForTesting
List<Attachment> dedupeAttachmentsByExactIdentity(Iterable<Attachment> attachments) {
  final deduplicated = <Attachment>[];
  final seen = <String>{};
  for (final attachment in attachments) {
    final attachmentId = _attachmentIdentity(attachment);
    final messageId = _messageIdentity(attachment.message.target);
    final sourceChatId = _sourceChatIdentity(attachment.message.target);
    if (attachmentId == null || messageId == null || sourceChatId == null) {
      deduplicated.add(attachment);
      continue;
    }
    if (seen.add('$sourceChatId\u0000$messageId\u0000$attachmentId')) {
      deduplicated.add(attachment);
    }
  }
  return deduplicated;
}

int compareLogicalAttachmentsDescending(Attachment left, Attachment right) {
  final leftMessage = left.message.target;
  final rightMessage = right.message.target;
  if (leftMessage != null && rightMessage != null) {
    final byMessage = compareLogicalMessagesDescending(leftMessage, rightMessage);
    if (byMessage != 0) return byMessage;
  } else if (leftMessage != null || rightMessage != null) {
    return leftMessage == null ? 1 : -1;
  }
  final bySource = (_sourceChatIdentity(leftMessage) ?? '').compareTo(_sourceChatIdentity(rightMessage) ?? '');
  if (bySource != 0) return bySource;
  return (_attachmentIdentity(left) ?? '').compareTo(_attachmentIdentity(right) ?? '');
}

/// Widget that handles loading attachments asynchronously with loading state
class AttachmentsLoader extends StatefulWidget {
  final Chat chat;
  final Function(List<Attachment>, List<Attachment>, List<Attachment>) onAttachmentsLoaded;

  const AttachmentsLoader({super.key, required this.chat, required this.onAttachmentsLoaded});

  @override
  State<AttachmentsLoader> createState() => _AttachmentsLoaderState();
}

class _AttachmentsLoaderState extends State<AttachmentsLoader> {
  bool isLoading = true;
  StreamSubscription? _membershipSubscription;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _membershipSubscription = EventDispatcherSvc.stream.listen((event) {
      if (event.type != logicalMembershipAdvancedEvent ||
          !shouldRefreshLogicalMembershipProjection(
            eventData: event.data,
            currentLogicalId: ChatsSvc.logicalConversationIdFor(widget.chat),
          )) {
        return;
      }
      unawaited(_fetchAttachments());
    });
    if (!kIsWeb) {
      unawaited(_fetchAttachments());
    } else {
      isLoading = false;
    }
  }

  @override
  void didUpdateWidget(AttachmentsLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!kIsWeb && ChatsSvc.conversationKeyFor(oldWidget.chat) != ChatsSvc.conversationKeyFor(widget.chat)) {
      unawaited(_fetchAttachments());
    }
  }

  @override
  void dispose() {
    _membershipSubscription?.cancel();
    super.dispose();
  }

  Future<void> _fetchAttachments() async {
    final loadEpoch = ++_loadEpoch;
    if (mounted) setState(() => isLoading = true);
    try {
      final sourceChats = {
        for (final source in ChatsSvc.logicalSourceChatsFor(widget.chat)) source.guid: source,
      }.values.toList(growable: false);
      if (sourceChats.isEmpty || sourceChats.any((source) => source.id == null)) {
        throw StateError('A certified source chat is unavailable locally');
      }
      final sourceAttachments = await Future.wait(sourceChats.map((source) => source.getAttachmentsAsync()));
      final attachments = dedupeAttachmentsByExactIdentity(sourceAttachments.expand((items) => items));

      if (!mounted || loadEpoch != _loadEpoch) return;

      final media =
          attachments
              .where(
                (e) =>
                    !(e.message.target?.isGroupEvent ?? true) &&
                    !(e.message.target?.isInteractive ?? true) &&
                    (e.mimeStart == "image" || e.mimeStart == "video"),
              )
              .toList()
            ..sort(compareLogicalAttachmentsDescending);

      final docs =
          attachments
              .where(
                (e) =>
                    !(e.message.target?.isGroupEvent ?? true) &&
                    !(e.message.target?.isInteractive ?? true) &&
                    e.mimeStart != "image" &&
                    e.mimeStart != "video" &&
                    !(e.mimeType ?? "").contains("location"),
              )
              .toList()
            ..sort(compareLogicalAttachmentsDescending);

      final locations = attachments.where((e) => (e.mimeType ?? "").contains("location")).toList()
        ..sort(compareLogicalAttachmentsDescending);

      setState(() {
        isLoading = false;
      });

      widget.onAttachmentsLoaded(media, docs, locations);
    } catch (e) {
      if (mounted && loadEpoch == _loadEpoch) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // This widget doesn't render anything visible itself
    // It just triggers the loading and callbacks
    return const SizedBox.shrink();
  }
}
