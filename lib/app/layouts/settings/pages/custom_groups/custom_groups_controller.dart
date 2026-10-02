import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/backend/interfaces/custom_group_interface.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:get/get.dart';

class CustomGroupsController extends GetxController {
  final RxList<CustomGroup> groups = <CustomGroup>[].obs;
  final RxBool loading = true.obs;

  StreamSubscription? _eventSub;

  @override
  void onInit() {
    super.onInit();
    loadGroups();
    _eventSub = EventDispatcherSvc.stream.listen((event) {
      if (event.type == 'custom-groups-updated') loadGroups();
    });
  }

  @override
  void onClose() {
    _eventSub?.cancel();
    super.onClose();
  }

  Future<void> loadGroups() async {
    loading.value = true;
    groups.value = await CustomGroupInterface.getAll();
    loading.value = false;
  }

  Future<void> createGroup(String name, List<Chat> chats) async {
    final ordinaryGuids = chats
        .where((chat) => !ChatsSvc.isLogicalConversation(chat))
        .map((chat) => chat.guid)
        .toList();
    final group = await CustomGroupInterface.create(name: name, chatGuids: ordinaryGuids);
    for (final chat in chats.where(ChatsSvc.isLogicalConversation)) {
      await ChatsSvc.setConversationCustomGroupMembership(chat, group.id!, true);
    }
  }

  List<Chat> chatsForGroup(CustomGroup group) =>
      ChatsSvc.allChats.where((chat) => ChatsSvc.isConversationInCustomGroup(chat, group.id!)).toList();

  List<String> initialSelectionForGroup(CustomGroup group) =>
      chatsForGroup(group).map((chat) => chat.guid).toList(growable: false);

  Future<void> renameGroup(CustomGroup group, String name) async {
    await CustomGroupInterface.rename(id: group.id!, name: name);
  }

  Future<void> updateGroupChats(CustomGroup group, List<Chat> chats) async {
    final selectedKeys = chats.map(ChatsSvc.conversationKeyFor).toSet();
    for (final logicalChat in ChatsSvc.allChats.where(ChatsSvc.isLogicalConversation)) {
      await ChatsSvc.setConversationCustomGroupMembership(
        logicalChat,
        group.id!,
        selectedKeys.contains(ChatsSvc.conversationKeyFor(logicalChat)),
      );
    }
    final protectedExistingPhysicalGuids = group.chats.where(ChatsSvc.isApprovedLogicalSource).map((chat) => chat.guid);
    final ordinarySelectedGuids = chats.where((chat) => !ChatsSvc.isLogicalConversation(chat)).map((chat) => chat.guid);
    await CustomGroupInterface.updateChats(
      id: group.id!,
      chatGuids: <String>{...protectedExistingPhysicalGuids, ...ordinarySelectedGuids}.toList(),
    );
  }

  Future<void> setShowUnreadBadge(CustomGroup group, bool value) async {
    await CustomGroupInterface.setShowUnreadBadge(id: group.id!, value: value);
  }

  Future<void> deleteGroup(CustomGroup group) async {
    await CustomGroupInterface.delete(id: group.id!);
  }

  Future<void> reorderGroups(List<CustomGroup> newOrder) async {
    groups.value = newOrder;
    await CustomGroupInterface.reorder(ids: newOrder.map((g) => g.id!).toList());
  }
}
