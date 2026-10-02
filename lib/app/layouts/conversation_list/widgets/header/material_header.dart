import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/header/header_widgets.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_view.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';

class MaterialHeader extends CustomStateful<ConversationListController> {
  const MaterialHeader({super.key, required super.parentController});

  @override
  State<StatefulWidget> createState() => _MaterialHeaderState();
}

class _MaterialHeaderState extends CustomState<MaterialHeader, void, ConversationListController> {
  bool get showArchived => controller.showArchivedChats;

  bool get showUnknown => controller.showUnknownSenders;

  bool get localStateMutationAllowed => controller.selectedChats.every(ChatsSvc.canApplyConversationLocalStateMutation);

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Obx(
          () => Container(
            height: controller.selectedChats.isEmpty ? 100 : null,
            width: NavigationSvc.width(context),
            color: SettingsSvc.settings.windowEffect.value == WindowEffect.disabled
                ? context.theme.colorScheme.surfaceContainerHighest
                : Colors.transparent,
          ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
          child: controller.selectedChats.isEmpty
              ? SafeArea(
                  child: Obx(() {
                    NavigationSvc.listener.value;
                    return Container(
                      decoration: BoxDecoration(
                        color: !NavigationSvc.isAvatarOnly(context) && !showArchived && !showUnknown
                            ? context.theme.colorScheme.surfaceContainerHighest.withValues(
                                alpha: SettingsSvc.settings.windowEffect.value == WindowEffect.disabled ? 1 : 0.7,
                              )
                            : Colors.transparent,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(left: 5.0, top: 6.0, bottom: 6.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.start,
                          children: [
                            if (NavigationSvc.isAvatarOnly(context))
                              Material(
                                color: Colors.transparent,
                                shape: const CircleBorder(),
                                clipBehavior: Clip.antiAlias,
                                child: OverflowMenu(extraItems: true, controller: controller),
                              ),
                            if (!NavigationSvc.isAvatarOnly(context))
                              Padding(
                                padding: const EdgeInsets.only(left: 18, right: 10),
                                child: (!showArchived && !showUnknown)
                                    ? SvgPicture.asset(
                                        'assets/icon/bb-icon.svg',
                                        width: 26,
                                        height: 26,
                                        colorFilter: ColorFilter.mode(
                                          context.theme.colorScheme.onSurfaceVariant,
                                          BlendMode.srcIn,
                                        ),
                                      )
                                    : IconButton(
                                        onPressed: () async {
                                          Navigator.of(context).pop();
                                        },
                                        padding: EdgeInsets.zero,
                                        icon: Icon(Icons.arrow_back, color: context.theme.colorScheme.onSurfaceVariant),
                                      ),
                              ),
                            if (!NavigationSvc.isAvatarOnly(context)) HeaderText(controller: controller, fontSize: 18),
                            if (!NavigationSvc.isAvatarOnly(context) && !showArchived && !showUnknown)
                              Expanded(
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () async {
                                        controller.openCamera(context);
                                      },
                                      icon: Icon(
                                        Icons.camera_alt_outlined,
                                        color: context.theme.colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(left: 2),
                                      child: IconButton(
                                        onPressed: () async {
                                          NavigationSvc.pushLeft(context, const SearchView());
                                        },
                                        icon: Icon(
                                          Icons.search_rounded,
                                          color: context.theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    const ChatListFilterButton(),
                                    const Padding(padding: EdgeInsets.only(right: 8), child: OverflowMenu()),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                )
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 20.0, left: 20.0, top: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              onPressed: () {
                                controller.clearSelectedChats();
                              },
                              icon: Icon(Icons.close, color: context.theme.colorScheme.primary),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              controller.selectedChats.length.toString(),
                              style: context.theme.textTheme.titleLarge!.copyWith(
                                color: context.theme.colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
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
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
