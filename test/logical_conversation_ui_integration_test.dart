import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_details/widgets/chat_info.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/participants_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/conversation_list.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_models.dart';
import 'package:bluebubbles/app/layouts/conversation_list/pages/search/search_view.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/pinned_conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_list/widgets/tile/conversation_tile.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/app/state/chat_state.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/backend_ui_interop/event_dispatcher.dart' as bb_events;
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get_it/get_it.dart';

import 'support/logical_read_certificate_fixture.dart';

class _UiTestChatsService extends ChatsService {
  _UiTestChatsService({this.logicalDrafts = const <String, LogicalDraftPreview>{}, this.certifiedRows = const <int>{}});

  final Map<String, LogicalDraftPreview> logicalDrafts;
  final Set<int> certifiedRows;

  @override
  bool isLogicalConversation(Chat chat) => logicalDrafts.containsKey(chat.guid);

  @override
  LogicalDraftPreview? logicalDraftPreviewFor(Chat chat) => logicalDrafts[chat.guid];

  @override
  String conversationKeyFor(Chat chat) => certifiedRows.contains(chat.originalROWID)
      ? LogicalConversationId.certified(LogicalConversationViewPolicy.bankedLogicalConversationId).value
      : super.conversationKeyFor(chat);
}

class _UiTestThemesService extends ThemesService {
  @override
  bool get isAnyMaterialYouSelected => false;

  @override
  bool isMaterialYouActive(BuildContext context) => false;

  @override
  bool inDarkMode(BuildContext context) => false;
}

class _RecordingNavigatorService extends NavigatorService {
  Widget? pushedWidget;

  @override
  Future<void> pushAndRemoveUntil(
    BuildContext context,
    Widget widget,
    bool Function(Route<dynamic>) predicate, {
    bool closeActiveChat = true,
    PageRoute<dynamic>? customRoute,
  }) async {
    pushedWidget = widget;
  }
}

const _firstGuid = 'iMessage;+;chat-DA020133DFBE35D80A6994E1';
const _secondGuid = 'SMS;+;chat-760EDF8A92C1CE7A9848BFFE';
const _presentationGuid = 'SMS;+;chat-7711D5BC6430FC79835776C5';

Chat _chat({required int rowId, required String guid, String? title}) =>
    Chat(originalROWID: rowId, guid: guid, chatIdentifier: 'chat-$rowId', displayName: title, style: 43);

Iterable<String> _richTextValues(WidgetTester tester) =>
    tester.widgetList<RichText>(find.byType(RichText)).map((widget) => widget.text.toPlainText());

void main() {
  late Directory temporaryDirectory;
  late SettingsService settingsService;

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    await GetIt.I.reset();
    LogicalConversationViewPolicy.resetRuntimeCertificateForTesting();

    temporaryDirectory = await Directory.systemTemp.createTemp('bluebubbles-logical-ui-test.');

    settingsService = SettingsService()..settings = Settings();
    settingsService.settings.skin.value = Skins.Material;
    settingsService.settings.tabletMode.value = false;

    final filesystemService = FilesystemService()..appDocDir = temporaryDirectory;
    GetIt.I.registerSingleton<SettingsService>(settingsService);
    GetIt.I.registerSingleton<FilesystemService>(filesystemService);
    GetIt.I.registerSingleton<HandleService>(HandleService());
    GetIt.I.registerSingleton<ThemesService>(_UiTestThemesService());
    GetIt.I.registerSingleton<bb_events.EventDispatcher>(bb_events.EventDispatcher());
  });

  tearDown(() async {
    LogicalConversationViewPolicy.resetRuntimeCertificateForTesting();
    Get.reset();
    await GetIt.I.reset();
    if (temporaryDirectory.existsSync()) temporaryDirectory.deleteSync(recursive: true);
  });

  testWidgets('certified members render one stable keyed row while an ordinary chat remains independent', (
    tester,
  ) async {
    final chatsService = _UiTestChatsService(certifiedRows: const <int>{2027, 2155, 2156});
    GetIt.I.registerSingleton<ChatsService>(chatsService);

    final physicalMembers = <Chat>[
      _chat(rowId: 2027, guid: _firstGuid),
      _chat(rowId: 2155, guid: _secondGuid),
      _chat(rowId: 2156, guid: _presentationGuid, title: 'Certified conversation'),
    ];
    final ordinary = _chat(rowId: 3000, guid: 'ordinary-guid', title: 'Ordinary conversation');

    expect(
      LogicalConversationViewPolicy.bindRuntimeCertificate(
        physicalChats: bankedReadFixtureBindings(),
        persistedCertificateJson: null,
      ),
      isTrue,
    );

    final keys = physicalMembers.map(chatsService.conversationKeyFor).toSet();
    expect(keys, hasLength(1));
    final logicalKey = keys.single;
    expect(
      logicalKey,
      LogicalConversationId.certified(LogicalConversationViewPolicy.bankedLogicalConversationId).value,
    );
    expect(chatsService.conversationKeyFor(ordinary), ordinary.guid);

    Widget rowsFor(List<Chat> source) {
      final rows = LogicalConversationViewPolicy.projectConversationList(source, (chat) => chat.originalROWID);
      return MaterialApp(
        home: ListView(
          children: [
            for (final row in rows)
              SizedBox(
                key: ValueKey<String>(chatsService.conversationKeyFor(row)),
                child: Text(row.displayName ?? row.guid),
              ),
          ],
        ),
      );
    }

    await tester.pumpWidget(rowsFor(<Chat>[...physicalMembers, ordinary]));
    expect(find.byKey(ValueKey<String>(logicalKey)), findsOneWidget);
    expect(find.byKey(ValueKey<String>(ordinary.guid)), findsOneWidget);
    expect(find.byKey(const ValueKey<String>(_firstGuid)), findsNothing);
    expect(find.byKey(const ValueKey<String>(_secondGuid)), findsNothing);
    expect(find.byKey(const ValueKey<String>(_presentationGuid)), findsNothing);
    final logicalElement = find.byKey(ValueKey<String>(logicalKey)).evaluate().single;

    await tester.pumpWidget(rowsFor(<Chat>[ordinary, ...physicalMembers.reversed]));
    expect(find.byKey(ValueKey<String>(logicalKey)), findsOneWidget);
    expect(find.byKey(ValueKey<String>(ordinary.guid)), findsOneWidget);
    expect(find.byKey(ValueKey<String>(logicalKey)).evaluate().single, same(logicalElement));
  });

  testWidgets('view-controller lookups stay pure while explicit presentation ownership can rebind', (tester) async {
    final chatsService = _UiTestChatsService(certifiedRows: const <int>{2027, 2155, 2156});
    GetIt.I.registerSingleton<ChatsService>(chatsService);
    final listController = ConversationListController(showArchivedChats: false, showUnknownSenders: false);
    final fallback = _chat(rowId: 2027, guid: _firstGuid, title: 'Fallback member');
    final preferred = _chat(rowId: 2156, guid: _presentationGuid, title: 'Preferred member');

    final firstTile = ConversationTile(chat: fallback, controller: listController);
    final logicalKey = chatsService.conversationKeyFor(fallback);
    expect(firstTile.parentController.chat, same(fallback));

    final preferredTile = ConversationTile(chat: preferred, controller: listController);
    expect(preferredTile.parentController, same(firstTile.parentController));
    expect(preferredTile.parentController.chat, same(preferred));
    expect(chatsService.conversationKeyFor(preferredTile.parentController.chat), logicalKey);

    final fallbackAgain = ConversationTile(chat: fallback, controller: listController);
    expect(fallbackAgain.parentController, same(firstTile.parentController));
    expect(fallbackAgain.parentController.chat, same(fallback));

    final firstPinned = PinnedConversationTile(chat: fallback, controller: listController, avatarSize: 48);
    final preferredPinned = PinnedConversationTile(chat: preferred, controller: listController, avatarSize: 48);
    expect(preferredPinned.parentController, same(firstPinned.parentController));
    expect(preferredPinned.parentController.chat, same(preferred));
    final fallbackPinned = PinnedConversationTile(chat: fallback, controller: listController, avatarSize: 48);
    expect(fallbackPinned.parentController, same(firstPinned.parentController));
    expect(fallbackPinned.parentController.chat, same(fallback));

    final firstViewController = cvc(fallback);
    final preferredViewController = cvc(preferred);
    expect(preferredViewController, same(firstViewController));
    // Read-side helpers call cvc() while constructing every message. Those
    // lookups must not mutate the shared controller presentation or they dirty
    // the whole conversation route during SliverList child construction.
    expect(preferredViewController.chat, same(fallback));
    expect(preferredViewController.tag, logicalKey);

    preferredViewController.rebindPresentation(preferred);
    expect(preferredViewController.chat, same(preferred));

    final fallbackViewController = cvc(fallback);
    expect(fallbackViewController, same(firstViewController));
    expect(fallbackViewController.chat, same(preferred));

    final explicitlyBoundController = cvc(fallback, bindPresentation: true);
    expect(explicitlyBoundController, same(firstViewController));
    expect(explicitlyBoundController.chat, same(fallback));

    var routeBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Obx(() {
          routeBuilds++;
          final presentation = firstViewController.chat;
          for (var i = 0; i < 1000; i++) {
            cvc(_chat(rowId: 2027, guid: _firstGuid, title: 'Hydrated source $i'));
          }
          return Text(presentation.guid);
        }),
      ),
    );
    await tester.pump();
    expect(routeBuilds, 1);
    expect(firstViewController.chat, same(fallback));
  });

  testWidgets('ChatSubtitle selects durable logical draft and preserves ordinary ChatState draft behavior', (
    tester,
  ) async {
    final logicalPreview = LogicalDraftPreview.fromValues(text: 'Durable logical draft', attachmentCount: 1)!;
    final chatsService = _UiTestChatsService(
      logicalDrafts: <String, LogicalDraftPreview>{'logical-presentation': logicalPreview},
    );
    GetIt.I.registerSingleton<ChatsService>(chatsService);

    final logicalChat = Chat(
      guid: 'logical-presentation',
      chatIdentifier: 'logical-presentation',
      textFieldText: 'Stale physical draft',
    );
    final ordinaryChat = Chat(
      guid: 'ordinary-draft',
      chatIdentifier: 'ordinary-draft',
      textFieldText: 'Ordinary ChatState draft',
    );
    final logicalState = ChatState(logicalChat);
    final ordinaryState = ChatState(ordinaryChat);
    final listController = ConversationListController(showArchivedChats: false, showUnknownSenders: false);

    Widget subtitleFor(ChatState state) => MaterialApp(
      home: Scaffold(
        body: ChatSubtitle(
          parentController: ConversationTileController(chatState: state, listController: listController),
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
      ),
    );

    await tester.pumpWidget(subtitleFor(logicalState));
    expect(_richTextValues(tester), contains('Draft: Durable logical draft'));
    expect(_richTextValues(tester), isNot(contains('Draft: Stale physical draft')));

    await tester.pumpWidget(subtitleFor(ordinaryState));
    expect(_richTextValues(tester), contains('Draft: Ordinary ChatState draft'));
    expect(_richTextValues(tester), isNot(contains('Draft: Durable logical draft')));
  });

  testWidgets('ParticipantsList suppresses the mutation action in logical read-only mode', (tester) async {
    GetIt.I.registerSingleton<ChatsService>(_UiTestChatsService());
    settingsService.settings.enablePrivateAPI.value = true;
    final group = Chat(guid: 'iMessage;+;details-fixture', chatIdentifier: 'details-fixture', style: 43);

    Widget detailsFor({required bool readOnly}) => MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: <Widget>[ParticipantsList(chat: group, readOnly: readOnly)],
        ),
      ),
    );

    await tester.pumpWidget(detailsFor(readOnly: false));
    expect(find.text('Add people'), findsOneWidget);

    await tester.pumpWidget(detailsFor(readOnly: true));
    expect(find.text('Add people'), findsNothing);
  });

  testWidgets('read-only logical ChatInfo does not create an empty Obx observer', (tester) async {
    GetIt.I.registerSingleton<ChatsService>(_UiTestChatsService());
    settingsService.settings.skin.value = Skins.iOS;
    final group = Chat(
      guid: 'SMS;+;logical-details-fixture',
      chatIdentifier: 'logical-details-fixture',
      displayName: 'Certified logical conversation',
      style: 43,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ChatInfo(chat: group, readOnly: true)),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Certified logical conversation', findRichText: true), findsOneWidget);
  });

  testWidgets('search result tap navigates through presentation chat with the exact source message anchor', (
    tester,
  ) async {
    final chatsService = _UiTestChatsService();
    final navigator = _RecordingNavigatorService();
    GetIt.I.registerSingleton<ChatsService>(chatsService);
    Get.put<NavigatorService>(navigator, permanent: true);

    final presentation = Chat(
      guid: 'presentation-chat',
      chatIdentifier: 'presentation-chat',
      displayName: 'Presentation conversation',
    );
    final source = Chat(guid: 'physical-source-chat', chatIdentifier: 'physical-source-chat');
    final message = Message(
      guid: 'exact-source-message',
      text: 'A needle in the exact physical source',
      dateCreated: DateTime.fromMillisecondsSinceEpoch(1000),
      isFromMe: false,
    )..chat.target = source;
    final result = SearchResultItem(presentationChat: presentation, sourceChat: source, message: message);

    await tester.pumpWidget(const MaterialApp(home: SearchView()));
    final state = tester.state<SearchViewState>(find.byType(SearchView));
    state.currentSearchTerm.value = 'needle';
    state.currentSearch.value = SearchResult(
      search: 'needle',
      mode: SearchMode.local,
      results: <SearchResultItem>[result],
    );
    state.local.value = true;
    state.network.value = false;
    await tester.pump();

    expect(find.text('Presentation conversation', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Presentation conversation', findRichText: true));
    await tester.pump();

    expect(navigator.pushedWidget, isA<ConversationView>());
    final destination = navigator.pushedWidget! as ConversationView;
    expect(destination.chat, same(presentation));
    expect(destination.chat, isNot(same(source)));
    expect(destination.initialScrollToGuid, message.guid);
    expect(destination.customService?.tag, presentation.guid);
    expect(destination.customService?.struct.getMessage(message.guid!), same(message));
  });
}
