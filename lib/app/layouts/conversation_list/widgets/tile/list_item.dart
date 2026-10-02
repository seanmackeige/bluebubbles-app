import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ListItem extends StatelessWidget {
  final Chat chat;
  final ConversationListController controller;
  final VoidCallback update;
  const ListItem({super.key, required this.chat, required this.controller, required this.update});

  MaterialSwipeAction get leftAction => SettingsSvc.settings.materialLeftAction.value;
  MaterialSwipeAction get rightAction => SettingsSvc.settings.materialRightAction.value;

  Widget slideBackground(Chat chat, bool left) {
    MaterialSwipeAction action;
    if (left) {
      action = leftAction;
    } else {
      action = rightAction;
    }

    return Container(
      color: action == MaterialSwipeAction.pin
          ? Colors.yellow[800]
          : action == MaterialSwipeAction.alerts
          ? Colors.purple
          : action == MaterialSwipeAction.delete
          ? Colors.red
          : action == MaterialSwipeAction.mark_read
          ? Colors.blue
          : Colors.red,
      child: Align(
        alignment: left ? Alignment.centerRight : Alignment.centerLeft,
        child: Row(
          mainAxisAlignment: left ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: <Widget>[
            const SizedBox(width: 20),
            Icon(
              action == MaterialSwipeAction.pin
                  ? (ChatsSvc.isConversationPinned(chat) ? Icons.star_outline : Icons.star)
                  : action == MaterialSwipeAction.alerts
                  ? (ChatsSvc.isConversationMuted(chat) ? Icons.notifications_active : Icons.notifications_off)
                  : action == MaterialSwipeAction.delete
                  ? Icons.delete_forever_outlined
                  : action == MaterialSwipeAction.mark_read
                  ? (ChatsSvc.isConversationUnread(chat) ? Icons.mark_chat_read : Icons.mark_chat_unread)
                  : (ChatsSvc.isConversationArchived(chat) ? Icons.unarchive : Icons.archive),
              color: Colors.white,
            ),
            Text(
              action == MaterialSwipeAction.pin
                  ? (ChatsSvc.isConversationPinned(chat) ? " Unpin" : " Pin")
                  : action == MaterialSwipeAction.alerts
                  ? (ChatsSvc.isConversationMuted(chat) ? ' Show Alerts' : ' Hide Alerts')
                  : action == MaterialSwipeAction.delete
                  ? " Delete"
                  : action == MaterialSwipeAction.mark_read
                  ? (ChatsSvc.isConversationUnread(chat) ? ' Mark Read' : ' Mark Unread')
                  : (ChatsSvc.isConversationArchived(chat) ? ' Unarchive' : ' Archive'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              textAlign: left ? TextAlign.right : TextAlign.left,
            ),
            const SizedBox(width: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // No need for Obx here - ConversationTile handles its own reactivity
    final tile = ConversationTile(
      key: Key(ChatsSvc.conversationKeyFor(chat)),
      chat: chat,
      controller: controller,
      onSelect: (bool isSelected) {
        if (isSelected) {
          controller.selectedChats.add(chat);
          controller.updateSelectedChats();
        } else {
          controller.selectedChats.removeWhere((element) => element.guid == chat.guid);
          controller.updateSelectedChats();
        }
      },
    );

    if (SettingsSvc.settings.swipableConversationTiles.value) {
      return Dismissible(
        background: (kIsDesktop || kIsWeb) ? null : Obx(() => slideBackground(chat, false)),
        secondaryBackground: (kIsDesktop || kIsWeb) ? null : Obx(() => slideBackground(chat, true)),
        key: ValueKey('dismiss-${ChatsSvc.conversationKeyFor(chat)}'),
        confirmDismiss: (direction) async {
          final action = direction == DismissDirection.endToStart ? leftAction : rightAction;
          final protectedSource = ChatsSvc.isPotentialLogicalSource(chat);
          final localStateMutationAllowed = ChatsSvc.canApplyConversationLocalStateMutation(chat);
          if (action == MaterialSwipeAction.delete && protectedSource) {
            showToast('Delete unavailable while conversation identity is protected.');
            return false;
          }
          if (action != MaterialSwipeAction.delete && !localStateMutationAllowed) {
            showToast('Conversation action unavailable while identity is being verified.');
            return false;
          }
          return true;
        },
        onDismissed: (direction) async {
          MaterialSwipeAction action;
          if (direction == DismissDirection.endToStart) {
            action = leftAction;
          } else {
            action = rightAction;
          }

          if (action == MaterialSwipeAction.pin) {
            final chatState = ChatsSvc.getChatState(chat.guid);
            ChatsSvc.setChatPinned(chatState?.chat ?? chat, !ChatsSvc.isConversationPinned(chat));
          } else if (action == MaterialSwipeAction.alerts) {
            await ChatsSvc.setChatMuted(chat, !ChatsSvc.isConversationMuted(chat));
          } else if (action == MaterialSwipeAction.delete) {
            ChatsSvc.removeChat(chat);
            ChatsSvc.softDeleteChat(chat);
          } else if (action == MaterialSwipeAction.mark_read) {
            await ChatsSvc.toggleConversationUnreadFromUi(chat);
          } else if (action == MaterialSwipeAction.archive) {
            await ChatsSvc.setChatArchived(chat, !ChatsSvc.isConversationArchived(chat));
          }
          update.call();
        },
        child: tile,
      );
    } else {
      return tile;
    }
  }
}
