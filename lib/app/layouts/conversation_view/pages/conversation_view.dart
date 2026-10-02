import 'dart:async';
import 'dart:convert';

import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/cupertino_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/header/material_header.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/messages_view_components.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart';
import 'package:bluebubbles/app/state/chat_state_scope.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/app/wrappers/gradient_background_wrapper.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/pages/messages_view.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/effects/screen_effects_widget.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_view.dart';
import 'package:bluebubbles/services/ui/chat/logical_operator_explanations.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/window_effect.dart';
import 'package:get/get.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.chat,
    this.customService,
    this.initialScrollToGuid,
    this.fromChatCreator = false,
  });

  final Chat chat;
  final MessagesService? customService;
  final String? initialScrollToGuid;
  final bool fromChatCreator;

  @override
  ConversationViewState createState() => ConversationViewState();
}

class ConversationViewState extends State<ConversationView> with ThemeHelpers<ConversationView>, RouteAware {
  late final ConversationViewController controller = cvc(widget.chat, tag: widget.customService?.tag);

  // Cache actions map to avoid rebuilding on every frame
  late final Map<Type, Action<Intent>> _actionsMap;

  // Cached stable widget subtrees. ConversationView.build() runs on every keyboard
  // animation frame because Scaffold/SafeArea subscribe to MediaQuery. Flutter
  // checks widget identity (child.widget == newWidget) before calling update() on
  // a child element — passing the same object instance skips the State rebuild
  // entirely, so MessagesView, GradientBackground, ConversationTextField, and the
  // header widgets will not rebuild on keyboard frames.
  late final Widget _bodyContent;
  late final PreferredSizeWidget _appBar;

  Chat get chat => controller.chat;

  void _onPanUpdate(DragUpdateDetails details) {
    if (!mounted) return;
    if (SettingsSvc.settings.swipeToCloseKeyboard.value && details.delta.dy > 0 && controller.keyboardOpen) {
      controller.focusNode.unfocus();
      controller.subjectFocusNode.unfocus();
    } else if (SettingsSvc.settings.swipeToOpenKeyboard.value && details.delta.dy < 0 && !controller.keyboardOpen) {
      controller.focusNode.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    controller.fromChatCreator = widget.fromChatCreator;
    controller.fromSearchResult = widget.initialScrollToGuid != null;
    ChatsSvc.setActiveChatSync(chat);
    ChatsSvc.activeChat?.controller = controller;
    Logger.debug("Conversation View initialized for ${chat.guid}");
    if (ChatsSvc.hasBuild99WriterCapability(chat)) {
      unawaited(ChatsSvc.prepareLogicalRoute(chat, force: true));
    }

    controller.loadReplyToMessageState(); // P224b

    // Build actions map once
    _buildActionsMap();

    // Cache the stable appBar and body subtrees. See field comments above.
    _appBar = _buildAppBar();
    _bodyContent = _buildBodyContent();

    // Warm the image cache for the custom background so it's ready on first paint.
    final bgPath = ChatsSvc.getChatState(chat.guid)?.customBackgroundPath.value;
    if (bgPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) precacheImage(FileImage(File(bgPath)), context);
      });
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return PreferredSize(
      preferredSize: Size(
        double.infinity, // width is ignored by Scaffold
        (kIsDesktop ? (!iOS ? 25 : 5) : 0) +
            90 * (iOS ? SettingsSvc.settings.avatarScale.value : 0) +
            (!iOS ? kToolbarHeight : 0),
      ),
      child: iOS ? CupertinoHeader(controller: controller) : MaterialHeader(controller: controller),
    );
  }

  Widget _buildBodyContent() {
    return GradientBackground(
      controller: controller,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const Positioned.fill(child: ScreenEffectsWidget()),
          Builder(
            builder: (context) {
              final bottomInset = MediaQuery.paddingOf(context).bottom;
              if (bottomInset <= 0) return const SizedBox.shrink();
              return Obx(
                () => Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: bottomInset,
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: controller.showAttachmentPicker.value
                          ? context.theme.colorScheme.surface
                          : Colors.transparent,
                    ),
                  ),
                ),
              );
            },
          ),
          Builder(
            builder: (context) {
              final bottomInset = MediaQuery.paddingOf(context).bottom;
              return Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Stack(
                        children: [
                          MessagesView(
                            key: Key(ChatsSvc.conversationKeyFor(chat)),
                            customService: widget.customService,
                            initialScrollToGuid: widget.initialScrollToGuid,
                            controller: controller,
                          ),
                          ScrollDownButton(controller: controller),
                        ],
                      ),
                    ),
                    if (ChatsSvc.isApprovedLogicalSource(chat))
                      _LogicalComposerGate(controller: controller, onPanUpdate: _onPanUpdate)
                    else
                      GestureDetector(
                        onPanUpdate: _onPanUpdate,
                        child: ConversationTextField(parentController: controller),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _buildActionsMap() {
    _actionsMap = {OpenChatDetailsIntent: OpenChatDetailsAction(context, widget.chat.guid)};

    if (SettingsSvc.settings.enablePrivateAPI.value) {
      _actionsMap.addAll({
        ReplyRecentIntent: ReplyRecentAction(widget.chat.guid),
        HeartRecentIntent: HeartRecentAction(widget.chat.guid),
        LikeRecentIntent: LikeRecentAction(widget.chat.guid),
        DislikeRecentIntent: DislikeRecentAction(widget.chat.guid),
        LaughRecentIntent: LaughRecentAction(widget.chat.guid),
        EmphasizeRecentIntent: EmphasizeRecentAction(widget.chat.guid),
        QuestionRecentIntent: QuestionRecentAction(widget.chat.guid),
      });
    }
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chat, widget.chat)) {
      controller.rebindPresentation(widget.chat);
      ChatsSvc.setActiveChatSync(controller.chat, clearNotifications: false, save: false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    // A route was pushed on top of the conversation view (e.g. ConversationDetails).
    controller.showingSubRoute = true;
  }

  @override
  void didPopNext() {
    // The route above was popped — conversation view is visible again.
    controller.showingSubRoute = false;
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    controller.saveReplyToMessageState(); // P8bda
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final windowEffect = SettingsSvc.settings.windowEffect.value;
      final chatState = ChatsSvc.getOrCreateChatState(controller.chat);
      return ChatStateScope(
        chatState: chatState,
        child: Builder(
          builder: (context) {
            final isDark = ThemeSvc.inDarkMode(context);
            chatState.themeVersion.value;
            final themeName = isDark ? chatState.customThemeDark.value : chatState.customThemeLight.value;
            final baseTheme = ThemeStruct.resolveByName(themeName, isDark ? Brightness.dark : Brightness.light).data;

            final colorScheme = baseTheme.colorScheme;
            final bubbleColors = baseTheme.extensions[BubbleColors] as BubbleColors?;
            final bubbleColor = bubbleColors != null
                ? (chat.isIMessage
                      ? bubbleColors.iMessageBubbleColor ?? colorScheme.iMessageBubble
                      : bubbleColors.smsBubbleColor ?? colorScheme.smsBubble)
                : colorScheme.bubble(context, chat.isIMessage);
            final onBubbleColor = bubbleColors != null
                ? (chat.isIMessage
                      ? bubbleColors.oniMessageBubbleColor ?? colorScheme.oniMessageBubble
                      : bubbleColors.onSmsBubbleColor ?? colorScheme.onSmsBubble)
                : colorScheme.onBubble(context, chat.isIMessage);

            return Theme(
              data: baseTheme.copyWith(
                // Override primary color with our custom bubble color.
                primaryColor: bubbleColor,
                colorScheme: colorScheme.copyWith(primary: bubbleColor, onPrimary: onBubbleColor),
              ),
              child: PopScope(
                canPop: false,
                onPopInvokedWithResult: <T>(bool didPop, T? result) async {
                  if (didPop) return;
                  if (controller.inSelectMode.value) {
                    controller.inSelectMode.value = false;
                    controller.selected.clear();
                    return;
                  }
                  if (controller.showAttachmentPicker.value) {
                    controller.showAttachmentPicker.value = false;
                    controller.updateWidgets<ConversationTextField>(null);
                    return;
                  }
                  if (LifecycleSvc.isBubble) {
                    SystemNavigator.pop();
                  }
                  controller.close();
                  if (LifecycleSvc.isBubble) return;
                  return Navigator.of(context).pop();
                },
                child: BBScaffold(
                  backgroundColor: windowEffect != WindowEffect.disabled ? Colors.transparent : colorScheme.surface,
                  extendBodyBehindAppBar: true,
                  appBar: _appBar,
                  body: Actions(actions: _actionsMap, child: _bodyContent),
                ),
              ),
            );
          },
        ),
      );
    });
  }
}

/// Fixed, non-interactive write boundary for a certified conversation that
/// has read identity but no banked Build 99 writer capability.
class CertifiedLogicalWriteUnavailableBanner extends StatelessWidget {
  const CertifiedLogicalWriteUnavailableBanner({super.key});

  @override
  Widget build(BuildContext context) => const SafeArea(
    top: false,
    bottom: false,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.lock_outline, size: 18),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              'Sending unavailable — this certified conversation is read-only',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    ),
  );
}

class _LogicalComposerGate extends StatelessWidget {
  const _LogicalComposerGate({required this.controller, required this.onPanUpdate});

  final ConversationViewController controller;
  final GestureDragUpdateCallback onPanUpdate;

  static String _blockedReason(LogicalRouteRuntimeStatus status) {
    return logicalRouteOperatorReason(status.reason, authorityState: status.authorityState);
  }

  static void _showDiagnostics(BuildContext context, LogicalRouteRuntimeStatus status) {
    final payload = <String, dynamic>{
      'stage': status.stage.name,
      'reason': status.reason,
      'authority_state': status.authorityState,
      'authority_epoch': status.authorityEpoch,
      'service': status.service,
      'transport': status.transportReason,
      ...?status.diagnostics,
    };
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send authority'),
        content: SingleChildScrollView(child: SelectableText(const JsonEncoder.withIndent('  ').convert(payload))),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ChatsSvc.hasBuild99WriterCapability(controller.chat)) {
      return const CertifiedLogicalWriteUnavailableBanner();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Obx(() {
          final status = ChatsSvc.logicalRouteRuntimeStatusFor(controller.chat);
          final ledger = LogicalAdmissionLedger.fromEntries(PrefsSvc.messaging.loadLogicalAdmissionLedger());
          final ambiguousOutcome =
              !ledger.isCorrupt &&
              ledger.hasAmbiguousOutcomeForLogical(LogicalConversationViewPolicy.bankedLogicalConversationId);
          final transportBlocked =
              status.isQualified && status.sendDisposition == LogicalTransportSendDisposition.blocked;
          if (status.isQualified && !transportBlocked && !ambiguousOutcome) {
            return const SizedBox.shrink();
          }
          final checking = !status.hasEvaluated && !ambiguousOutcome;
          final message = ambiguousOutcome
              ? 'Previous send outcome unknown • no automatic retry'
              : transportBlocked
              ? 'Send blocked — ${status.service ?? 'SMS'} relay unavailable'
              : checking
              ? 'Checking send authority…'
              : 'Send blocked — ${_blockedReason(status)}';
          return SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (checking)
                    const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    const Icon(Icons.lock_outline, size: 18),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
                  ),
                  if (!checking) ...[
                    IconButton(
                      tooltip: 'Send authority details',
                      onPressed: () => _showDiagnostics(context, status),
                      icon: const Icon(Icons.info_outline),
                    ),
                    IconButton(
                      tooltip: 'Check route again',
                      onPressed: () => unawaited(ChatsSvc.prepareLogicalRoute(controller.chat, force: true)),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
        GestureDetector(
          onPanUpdate: onPanUpdate,
          child: ConversationTextField(parentController: controller),
        ),
      ],
    );
  }
}
