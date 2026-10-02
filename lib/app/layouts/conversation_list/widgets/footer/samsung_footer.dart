import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SamsungFooter extends CustomStateful<ConversationListController> {
  const SamsungFooter({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _SamsungFooterState();
}

class _SamsungFooterState extends CustomState<SamsungFooter, void, ConversationListController> {
  bool get showArchived => controller.showArchivedChats;
  bool get showUnknown => controller.showUnknownSenders;

  bool get localStateMutationAllowed => controller.selectedChats.every(ChatsSvc.canApplyConversationLocalStateMutation);

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      transitionBuilder: (child, animation) => SizeTransition(sizeFactor: animation, child: child),
      child: controller.selectedChats.isEmpty
          ? const SizedBox.shrink()
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                if (([
                      0,
                      controller.selectedChats.length,
                    ]).contains(controller.selectedChats.where(ChatsSvc.isConversationUnread).length) &&
                    localStateMutationAllowed)
                  IconButton(
                    onPressed: () async {
                      for (Chat element in controller.selectedChats) {
                        await ChatsSvc.toggleConversationUnreadFromUi(element);
                      }
                      controller.clearSelectedChats();
                    },
                    icon: Icon(
                      ChatsSvc.isConversationUnread(controller.selectedChats[0])
                          ? Icons.mark_chat_read_outlined
                          : Icons.mark_chat_unread_outlined,
                      color: context.theme.colorScheme.primary,
                    ),
                  ),
                if (([
                      0,
                      controller.selectedChats.length,
                    ]).contains(controller.selectedChats.where(ChatsSvc.isConversationMuted).length) &&
                    localStateMutationAllowed)
                  IconButton(
                    onPressed: () async {
                      for (Chat element in controller.selectedChats) {
                        await ChatsSvc.setChatMuted(element, !ChatsSvc.isConversationMuted(element));
                      }
                      controller.clearSelectedChats();
                    },
                    icon: Icon(
                      ChatsSvc.isConversationMuted(controller.selectedChats[0])
                          ? Icons.notifications_active_outlined
                          : Icons.notifications_off_outlined,
                      color: context.theme.colorScheme.primary,
                    ),
                  ),
                if (([
                      0,
                      controller.selectedChats.length,
                    ]).contains(controller.selectedChats.where(ChatsSvc.isConversationPinned).length) &&
                    localStateMutationAllowed)
                  IconButton(
                    onPressed: () async {
                      for (Chat element in controller.selectedChats) {
                        await ChatsSvc.setChatPinned(element, !ChatsSvc.isConversationPinned(element));
                      }
                      controller.clearSelectedChats();
                    },
                    icon: Icon(
                      ChatsSvc.isConversationPinned(controller.selectedChats[0])
                          ? Icons.push_pin_outlined
                          : Icons.push_pin,
                      color: context.theme.colorScheme.primary,
                    ),
                  ),
                if (localStateMutationAllowed)
                  IconButton(
                    onPressed: () async {
                      for (Chat element in controller.selectedChats) {
                        await ChatsSvc.setChatArchived(element, !ChatsSvc.isConversationArchived(element));
                      }
                      controller.clearSelectedChats();
                    },
                    icon: Icon(
                      showArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
                      color: context.theme.colorScheme.primary,
                    ),
                  ),
                if (controller.selectedChats.every((chat) => !ChatsSvc.isPotentialLogicalSource(chat)))
                  IconButton(
                    onPressed: () {
                      for (Chat element in controller.selectedChats) {
                        ChatsSvc.removeChat(element);
                        ChatsSvc.softDeleteChat(element);
                      }
                      controller.clearSelectedChats();
                    },
                    icon: Icon(Icons.delete_outlined, color: context.theme.colorScheme.primary),
                  ),
              ],
            ),
    );
  }
}
