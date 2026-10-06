import 'logical_draft_confirmation_banner.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:bluebubbles/services/ui/chat/logical_draft_intent_guard.dart';
import 'dart:async';
import 'dart:math';

import 'package:audio_waveforms/audio_waveforms.dart';
import 'package:bluebubbles/app/components/custom_text_editing_controllers.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/media_picker/text_field_attachment_picker.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/message/send_animation.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/conversation_text_field_local_controller.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/helpers/text_field_match_helper.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_component.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_emoji_picker_section.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_icon_bar.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_recording_overlay.dart';
import 'package:bluebubbles/app/layouts/conversation_view/widgets/text_field/text_field_suffix.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show MessageReplyContext;
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/services/backend/typing_indicator_routing.dart';
import 'package:bluebubbles/services/ui/chat/send_data.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' show basename;
import 'package:permission_handler/permission_handler.dart';
import 'package:universal_io/io.dart';

export 'text_field_component.dart' show TextFieldComponent, TextFieldComponentState;

class ConversationTextField extends CustomStateful<ConversationViewController> {
  const ConversationTextField({super.key, required super.parentController});

  static ConversationTextFieldState? of(BuildContext context) {
    return context.findAncestorStateOfType<ConversationTextFieldState>();
  }

  @override
  ConversationTextFieldState createState() => ConversationTextFieldState();
}

class ConversationTextFieldState extends CustomState<ConversationTextField, void, ConversationViewController>
    with TickerProviderStateMixin {
  final recorderController = kIsWeb ? null : RecorderController();
  final localController = ConversationTextFieldLocalController();
  final _emojiScrollController = ScrollController();
  Worker? _logicalAttachmentDraftWorker;
  Worker? _logicalReplyDraftWorker;
  bool _logicalDraftConsumed = false;
  bool _restoringLogicalDraft = false;
  int _logicalIntentEpoch = 0;
  int _logicalUiGeneration = 0;
  Future<void>? _sendInFlight;
  final RxBool _confirmationBusy = false.obs;
  final RxBool _legacyConfirmationPresent = false.obs;
  final RxBool _confirmationFailed = false.obs;
  int _confirmationFailureDiagnosticCount = 0;
  final Rxn<LogicalDraftMetadataClass> _draftMetadataClass = Rxn<LogicalDraftMetadataClass>();

  void _refreshDraftConfirmationState() {
    if (!mounted || !_hasLogicalDraftIdentity) return;
    _draftMetadataClass.value = ChatsSvc.logicalDraftMetadataClassFor(chat);
    _legacyConfirmationPresent.value = ChatsSvc.loadLogicalDraft(chat)?.confirmation != null;
  }

  Future<void> _reviewAndConfirmDraft() async {
    if (_confirmationBusy.value || _sendInFlight != null || !_hasLogicalWriterCapability) return;
    _confirmationBusy.value = true;
    final ownerController = controller;
    final owner = ChatsSvc.conversationKeyFor(chat);
    final generation = ChatsSvc.logicalDraftGenerationFor(chat);
    final authorityAtReview = ChatsSvc.logicalWriterAuthorityRevisionFor(chat);
    var confirmationDraft = ChatsSvc.loadLogicalDraft(chat);
    final effectAtReview = confirmationDraft?.effectId;
    final text = controller.textController.text;
    final subject = controller.subjectTextController.text;
    final reply = jsonEncode(_logicalReplyIntent()?.toJson());
    final attachments = controller.pickedAttachments.toList(growable: false);
    final names = attachments.map((item) => item.name).toList(growable: false);
    final sizes = attachments.map((item) => item.size).toList(growable: false);
    final bundles = attachments.map((item) => item.balloonBundleId).toList(growable: false);
    bool visibleIsCurrent() =>
        mounted &&
        identical(controller, ownerController) &&
        ChatsSvc.conversationKeyFor(chat) == owner &&
        ChatsSvc.logicalDraftGenerationFor(chat) == generation &&
        !_logicalDraftConsumed &&
        controller.textController.text == text &&
        controller.subjectTextController.text == subject &&
        jsonEncode(_logicalReplyIntent()?.toJson()) == reply &&
        controller.pickedAttachments.length == attachments.length &&
        List.generate(attachments.length, (index) => index).every(
          (index) =>
              identical(controller.pickedAttachments[index], attachments[index]) &&
              attachments[index].name == names[index] &&
              attachments[index].size == sizes[index] &&
              attachments[index].balloonBundleId == bundles[index],
        );
    try {
      if (authorityAtReview == null ||
          ChatsSvc.logicalDraftMetadataClassFor(chat) != LogicalDraftMetadataClass.legacyUnboundDraft) {
        throw StateError('CONFIRMATION_NOT_ELIGIBLE');
      }
      localController.debounceDraftSave?.cancel();
      // Flush the exact currently visible intent before observing authority.
      // This saves content only; it cannot bind missing authority.
      final expected = await _saveLogicalDraft(effectId: effectAtReview);
      confirmationDraft = expected ?? confirmationDraft;
      if (!visibleIsCurrent() ||
          expected == null ||
          expected.text != text ||
          expected.subject != subject ||
          expected.effectId != effectAtReview ||
          expected.attachments.length != attachments.length ||
          expected.attachments.any((item) => !item.isRestorable)) {
        throw StateError('CONFIRMATION_VISIBLE_DRAFT_CHANGED');
      }
      final paths = attachments.map((item) => item.path).toList(growable: false);
      await ChatsSvc.confirmLegacyLogicalDraft(
        chat,
        expected: expected,
        authorityAtReview: authorityAtReview,
        composerIsCurrent: () =>
            visibleIsCurrent() &&
            List.generate(
              attachments.length,
              (index) => index,
            ).every((index) => attachments[index].path == paths[index]),
      );
      _confirmationFailed.value = false;
      if (mounted) showSnackbar('Draft confirmed', 'Nothing was sent. Send requires a separate tap.');
    } catch (error) {
      // Failure diagnostics are bounded and contain only hashes/fixed reasons.
      // A logger failure cannot promote readiness or touch the draft.
      if (_confirmationFailureDiagnosticCount++ < 8) {
        try {
          final report = logicalDraftConfirmationFailureRecord(
            draft: confirmationDraft,
            authorityAtReview: authorityAtReview,
            error: error,
          );
          for (final frame in logicalDraftDiagnosticFrames(report)) {
            Logger.info(frame, tag: 'LogicalDraftConfirmation');
            debugPrint(frame);
          }
        } catch (_) {
          /* Diagnostics are not an admission capability. */
        }
      }
      _confirmationFailed.value = true;
      if (mounted) showSnackbar('Confirmation paused', 'Your draft was preserved. Review it again before confirming.');
    } finally {
      if (mounted) {
        _confirmationBusy.value = false;
        _refreshDraftConfirmationState();
      }
    }
  }

  LogicalDraftIntentGuard? _activeIntentGuard;
  String? _admissionEffect;
  String? _retainedLogicalEffectId;
  void Function()? _finalAdmissionDiagnostic;
  bool Function()? _frozenComposerCurrent;

  LogicalReplyIntent? _retainedLogicalReplyIntent;
  final RxBool _logicalReplyResolutionPending = false.obs;

  Chat get chat => controller.chat;
  bool get _hasLogicalWriterCapability => ChatsSvc.hasBuild99WriterCapability(chat);
  bool get _hasLogicalDraftIdentity => ChatsSvc.isLogicalConversation(chat);
  bool get _isProtectedLogicalSource => ChatsSvc.isPotentialLogicalSource(chat);
  bool get _canMutateComposer => !_isProtectedLogicalSource || _hasLogicalWriterCapability;

  String get chatGuid => chat.guid;

  bool get showAttachmentPicker => controller.showAttachmentPicker.value;

  late final double emojiPickerHeight = max(256, context.height * 0.4);
  late final emojiColumns =
      NavigationSvc.width(context) ~/ 56; // Intentionally not responsive to prevent rebuilds when resizing
  RxBool get showEmojiPicker => controller.showEmojiPicker;

  final proxyController = TextEditingController();

  PlatformFile _freezeAttachment(PlatformFile source) => PlatformFile(
    path: source.path,
    name: source.name,
    size: source.size,
    bytes: source.bytes == null ? null : Uint8List.fromList(source.bytes!),
    balloonBundleId: source.balloonBundleId,
  );

  LogicalReplyIntent? _logicalReplyIntent() {
    final context = controller.replyToMessage;
    final selected = context?.message;
    final source = selected?.chat.target;
    if (context == null || selected?.guid == null || source?.originalROWID == null) {
      return _retainedLogicalReplyIntent;
    }
    return LogicalReplyIntent(
      messageGuid: selected!.guid!,
      relationshipTargetGuid: selected.threadOriginatorGuid ?? selected.guid!,
      sourceChatRowId: source!.originalROWID!,
      sourceChatGuid: source.guid,
      part: context.partIndex,
    );
  }

  Future<LogicalDraft?> _saveLogicalDraft({
    String? effectId,
    bool useFrozenIntent = false,
    String? frozenText,
    String? frozenSubject,
    List<PlatformFile>? frozenAttachments,
    LogicalReplyIntent? frozenReply,
  }) async {
    if (!_hasLogicalDraftIdentity) return null;
    if (_logicalDraftConsumed) return null;
    final expectedDraftGeneration = ChatsSvc.logicalDraftGenerationFor(chat);
    final selectedAttachments = useFrozenIntent ? frozenAttachments! : controller.pickedAttachments.toList();
    final saved = await ChatsSvc.saveLogicalSendIntent(
      chat,
      text: useFrozenIntent ? frozenText! : controller.textController.text,
      subject: useFrozenIntent ? frozenSubject! : controller.subjectTextController.text,
      attachments: selectedAttachments,
      reply: useFrozenIntent ? frozenReply : _logicalReplyIntent(),
      effectId: effectId ?? (_frozenComposerCurrent?.call() == true ? _admissionEffect : _retainedLogicalEffectId),
      expectedDraftGeneration: expectedDraftGeneration,
    );
    _refreshDraftConfirmationState();
    return saved;
  }

  void _markLogicalDraftConsumed() {
    _logicalDraftConsumed = true;
    _retainedLogicalEffectId = null;
    _logicalIntentEpoch += 1;
    _logicalUiGeneration += 1;
    _retainedLogicalReplyIntent = null;
    _logicalReplyResolutionPending.value = false;
    localController.debounceDraftSave?.cancel();
  }

  @override
  void initState() {
    super.initState();
    forceDelete = false;
    controller.logicalDraftConsumedFunc = _markLogicalDraftConsumed;

    // Load the initial chat drafts
    unawaited(getDrafts());

    if (_canMutateComposer && _hasLogicalDraftIdentity && !_logicalDraftConsumed) {
      _logicalAttachmentDraftWorker = ever(controller.pickedAttachments, (_) {
        if (_restoringLogicalDraft) return;
        _logicalUiGeneration += 1;
        if (_logicalDraftConsumed && controller.pickedAttachments.isEmpty) return;
        _logicalIntentEpoch += 1;
        _logicalDraftConsumed = false;
        localController.debounceDraftSave?.cancel();
        localController.debounceDraftSave = Timer(const Duration(milliseconds: 300), () {
          unawaited(_saveLogicalDraft());
        });
      });
      _logicalReplyDraftWorker = ever(controller.replyToMessageRx, (context) {
        if (_restoringLogicalDraft) return;
        _logicalUiGeneration += 1;
        if (_logicalDraftConsumed && context == null) return;
        _logicalIntentEpoch += 1;
        _logicalDraftConsumed = false;
        if (context == null) {
          _retainedLogicalReplyIntent = null;
          _logicalReplyResolutionPending.value = false;
        } else {
          final selected = context.message;
          final source = selected.chat.target;
          if (selected.guid != null && source?.originalROWID != null) {
            _retainedLogicalReplyIntent = LogicalReplyIntent(
              messageGuid: selected.guid!,
              relationshipTargetGuid: selected.threadOriginatorGuid ?? selected.guid!,
              sourceChatRowId: source!.originalROWID!,
              sourceChatGuid: source.guid,
              part: context.partIndex,
            );
          }
          _logicalReplyResolutionPending.value = false;
        }
        unawaited(_saveLogicalDraft());
      });
    }

    controller.textController.processMentions();

    // Save state
    localController.oldTextFieldSelection.value = controller.textController.selection;

    if (_canMutateComposer && controller.fromChatCreator) {
      controller.focusNode.requestFocus();
    } else if (_canMutateComposer && SettingsSvc.settings.autoOpenKeyboard.value && !controller.fromSearchResult) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.focusNode.requestFocus();
      });
    }

    controller.focusNode.addListener(() => focusListener(false));
    controller.subjectFocusNode.addListener(() => focusListener(true));

    controller.textController.addListener(() => textListener(false));
    controller.subjectTextController.addListener(() => textListener(true));

    if (kIsDesktop || kIsWeb) {
      proxyController.addListener(() {
        if (!_canMutateComposer) return;
        if (proxyController.text.isEmpty) return;
        String emoji = proxyController.text;
        proxyController.clear();
        TextEditingController realController =
            controller.editing.lastOrNull?.controller ?? controller.lastFocusedTextController;
        String text = realController.text;
        TextSelection selection = realController.selection;

        realController.text = text.substring(0, selection.start) + emoji + text.substring(selection.end);
        realController.selection = TextSelection.collapsed(offset: selection.start + emoji.length);

        (controller.editing.lastOrNull?.controller.focusNode ?? controller.lastFocusedNode).requestFocus();
      });
    }
  }

  Future<void> getDrafts() async {
    if (_hasLogicalDraftIdentity) {
      _refreshDraftConfirmationState();
      final generation = _logicalUiGeneration;
      bool isCurrent() => mounted && !_logicalDraftConsumed && generation == _logicalUiGeneration;
      _restoringLogicalDraft = true;
      try {
        final draft = ChatsSvc.loadLogicalDraft(chat);
        if (draft == null || !isCurrent()) return;
        _retainedLogicalEffectId = draft.effectId;
        if (draft.text.isNotEmpty) controller.textController.text = draft.text;
        if (draft.subject.isNotEmpty) controller.subjectTextController.text = draft.subject;
        // Suppress only synchronous restoration writes. Human events during
        // file IO must invalidate the pending restore generation.
        _restoringLogicalDraft = false;
        await getAttachmentDrafts(
          attachments: draft.attachments
              .where((item) => item.isRestorable)
              .map((item) => item.path)
              .whereType<String>()
              .toList(),
          isCurrent: isCurrent,
        );
        if (!isCurrent()) return;
        _restoringLogicalDraft = true;
        final reply = draft.reply;
        _logicalReplyResolutionPending.value = false;
        if (reply != null) {
          _retainedLogicalReplyIntent = reply;
          final message = Message.findOne(guid: reply.messageGuid);
          final source = message?.chat.target;
          if (message != null &&
              source?.originalROWID == reply.sourceChatRowId &&
              source?.guid == reply.sourceChatGuid) {
            controller.replyToMessage = MessageReplyContext(message, reply.part);
          } else {
            _logicalReplyResolutionPending.value = true;
          }
        }
      } finally {
        _restoringLogicalDraft = false;
      }
      return;
    }
    if (_isProtectedLogicalSource) return;
    getTextDraft();
    await getAttachmentDrafts();
  }

  void getTextDraft({String? text}) {
    // Skip restoring a draft when navigating from the chat creator — the send path
    // clears both the text controller and the persisted draft before navigating, so
    // any non-empty value here would be a stale artifact on the CVC's chat object.
    if (controller.fromChatCreator) return;
    // Read from ChatState — it is the source of truth and is always up-to-date,
    // even before the async DB write from a previous session has completed.
    final incomingText = text ?? ChatsSvc.getChatState(chatGuid)?.textFieldText.value ?? chat.textFieldText;
    if (incomingText != null && incomingText.isNotEmpty && incomingText != controller.textController.text) {
      controller.textController.text = incomingText;
    }
  }

  Future<void> getAttachmentDrafts({List<String> attachments = const [], bool Function()? isCurrent}) async {
    // Read from ChatState — it is the source of truth and is always up-to-date.
    // Fall back to chat.textFieldAttachments for the first load after a cold start
    // (before ChatState has been updated by any setChatTextFieldAttachments call).
    final incomingAttachments = isCurrent != null || attachments.isNotEmpty
        ? attachments
        : (ChatsSvc.getChatState(chatGuid)?.textFieldAttachments.toList() ?? chat.textFieldAttachments);
    final currentPicked = controller.pickedAttachments.map((element) => element.path).toList();
    final restored = <PlatformFile>[];
    for (String s in incomingAttachments) {
      final file = File(s);
      if (!currentPicked.contains(s) && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (isCurrent != null && !isCurrent()) return;
        restored.add(PlatformFile(name: basename(file.path), bytes: bytes, size: bytes.length, path: s));
      }
    }
    if (isCurrent != null && !isCurrent()) return;
    final wasRestoring = _restoringLogicalDraft;
    if (isCurrent != null) _restoringLogicalDraft = true;
    try {
      if (incomingAttachments.any((element) => !currentPicked.contains(element))) {
        controller.pickedAttachments.clear();
      }
      controller.pickedAttachments.addAll(restored);
    } finally {
      _restoringLogicalDraft = wasRestoring;
    }
  }

  void focusListener(bool subject) async {
    if (!_canMutateComposer) return;
    final _focusNode = subject ? controller.subjectFocusNode : controller.focusNode;
    // OPTIMIZATION: Only update if state actually needs to change
    if (_focusNode.hasFocus && controller.showAttachmentPicker.value) {
      controller.showAttachmentPicker.value = false;
    }
  }

  void textListener(bool subject) {
    final semanticText = "${controller.subjectTextController.text}\n${controller.textController.text}";
    if (!_restoringLogicalDraft && semanticText != localController.oldText.value) _logicalUiGeneration += 1;
    if (!_canMutateComposer) {
      localController.debounceDraftSave?.cancel();
      localController.debounceTyping?.cancel();
      return;
    }
    if (_hasLogicalDraftIdentity && !_logicalDraftConsumed) {
      _logicalIntentEpoch += 1;
    }
    if (_logicalDraftConsumed) {
      final hasNewIntent =
          controller.textController.text.isNotEmpty ||
          controller.subjectTextController.text.isNotEmpty ||
          controller.pickedAttachments.isNotEmpty;
      if (!hasNewIntent) return;
      _logicalDraftConsumed = false;
    }
    // OPTIMIZATION: Debounce draft saving to avoid database writes on every keystroke
    if (_hasLogicalDraftIdentity && !_logicalDraftConsumed) {
      localController.debounceDraftSave?.cancel();
      localController.debounceDraftSave = Timer(const Duration(milliseconds: 500), () {
        unawaited(_saveLogicalDraft());
      });
    } else if (!subject) {
      localController.debounceDraftSave?.cancel();
      localController.debounceDraftSave = Timer(const Duration(milliseconds: 500), () {
        unawaited(ChatsSvc.setChatTextFieldText(chat, controller.textController.text));
      });
    }

    // typing indicators and text change detection
    final newText = "${controller.subjectTextController.text}\n${controller.textController.text}";

    // OPTIMIZATION: Early exit if only selection changed (cursor moved), not text content
    if (newText == localController.oldText.value) {
      // Text unchanged, only update selection tracking for mentions
      if (!subject) {
        localController.oldTextFieldSelection.value = controller.textController.selection;
      }
      return;
    }

    if (!subject) {
      // Handle people arrow-keying or clicking into mentions
      String text = controller.textController.text;
      TextSelection selection = controller.textController.selection;

      // Work around an Android IME quirk where tapping the field while it already has
      // a collapsed cursor can report the new selection as a range anchored at the old
      // cursor position instead of collapsing to the tapped location. A plain tap should
      // never turn a collapsed cursor into a range, so treat this specific shape (base
      // pinned at the previous collapsed offset) as spurious and collapse it to the tap point.
      if (!selection.isCollapsed &&
          localController.oldTextFieldSelection.value.isCollapsed &&
          localController.oldTextFieldSelection.value.baseOffset == selection.baseOffset) {
        selection = TextSelection.collapsed(offset: selection.extentOffset);
        controller.textController.selection = selection;
      }

      if (selection.isCollapsed && selection.start != -1) {
        final behind = text.substring(0, selection.baseOffset);
        final behindMatches = MentionTextEditingController.escapingChar.allMatches(behind);
        if (behindMatches.length % 2 != 0) {
          // Assuming the rest of the code works, we're guaranteed to be inside a mention now
          final ahead = text.substring(selection.baseOffset);
          final aheadMatches = MentionTextEditingController.escapingChar.allMatches(ahead);

          // Now we determine which side of the mention to put the cursor on.
          // We can use the old selection to figure out if the user is moving left/right
          if (localController.oldTextFieldSelection.value.isCollapsed) {
            if (localController.oldTextFieldSelection.value.baseOffset > selection.baseOffset) {
              // moving left
              localController.oldTextFieldSelection.value = TextSelection.collapsed(offset: behindMatches.last.start);
              controller.textController.selection = localController.oldTextFieldSelection.value;
              return;
            } else if (localController.oldTextFieldSelection.value.baseOffset < selection.baseOffset) {
              // moving right
              localController.oldTextFieldSelection.value = TextSelection.collapsed(
                offset: behind.length + aheadMatches.first.end,
              );
              controller.textController.selection = localController.oldTextFieldSelection.value;
              return;
            }
          }

          // If we get here then we need to pick the closest side
          if (selection.baseOffset - behindMatches.last.end < aheadMatches.first.start - selection.baseOffset) {
            // moving left
            localController.oldTextFieldSelection.value = TextSelection.collapsed(offset: behindMatches.last.start);
            controller.textController.selection = localController.oldTextFieldSelection.value;
            return;
          } else {
            // Closer to right
            localController.oldTextFieldSelection.value = TextSelection.collapsed(
              offset: behind.length + aheadMatches.first.end,
            );
            controller.textController.selection = localController.oldTextFieldSelection.value;
            return;
          }
        }
      }

      if (!selection.isCollapsed && localController.oldTextFieldSelection.value.baseOffset == selection.baseOffset) {
        if (localController.oldTextFieldSelection.value.extentOffset < selection.extentOffset) {
          // Means we're shift+selecting rightwards
          final behind = text.substring(0, selection.extentOffset);
          final ahead = text.substring(selection.extentOffset);
          final aheadMatches = MentionTextEditingController.escapingChar.allMatches(ahead);
          if (aheadMatches.length % 2 != 0) {
            // Assuming the rest of the code works, we're guaranteed to be inside a mention now
            localController.oldTextFieldSelection.value = TextSelection(
              baseOffset: selection.baseOffset,
              extentOffset: behind.length + aheadMatches.first.end,
            );
            controller.textController.selection = localController.oldTextFieldSelection.value;
            return;
          }
        } else if (localController.oldTextFieldSelection.value.extentOffset > selection.extentOffset) {
          // Means we're shift+selecting leftwards
          final behind = text.substring(0, selection.extentOffset);
          final behindMatches = MentionTextEditingController.escapingChar.allMatches(behind);
          if (behindMatches.length % 2 != 0) {
            // Assuming the rest of the code works, we're guaranteed to be inside a mention now
            localController.oldTextFieldSelection.value = TextSelection(
              baseOffset: selection.baseOffset,
              extentOffset: behindMatches.last.start,
            );
            controller.textController.selection = localController.oldTextFieldSelection.value;
            return;
          }
        }
      }

      localController.oldTextFieldSelection.value = controller.textController.selection;
    }

    localController.debounceTyping?.cancel();
    localController.oldText.value = newText;
    // don't send a bunch of duplicate events for every typing change
    if (canDispatchOutboundTyping(isProtectedLogicalSource: _isProtectedLogicalSource) &&
        SettingsSvc.settings.enablePrivateAPI.value &&
        (chat.autoSendTypingIndicators ?? SettingsSvc.settings.privateSendTypingIndicators.value)) {
      if (localController.debounceTyping == null) {
        unawaited(TypingIndicatorSvc.startTyping(chatGuid));
      }
      localController.debounceTyping = Timer(const Duration(seconds: 3), () {
        unawaited(TypingIndicatorSvc.stopTyping(chatGuid));
        localController.debounceTyping = null;
      });
    }

    // OPTIMIZATION: Only run expensive emoji/mention matching if relevant characters present
    final _controller = subject ? controller.subjectTextController : controller.textController;
    final newEmojiText = _controller.text;

    // Debounce emoji search to avoid running regex on every keystroke
    if (newEmojiText.contains(":")) {
      localController.debounceEmojiSearch?.cancel();
      localController.debounceEmojiSearch = Timer(const Duration(milliseconds: 150), () {
        TextFieldMatchHelper.processEmojiMatches(controller, _controller, subject);
      });
    } else {
      localController.debounceEmojiSearch?.cancel();
      controller.emojiMatches.value = [];
      controller.emojiSelectedIndex.value = 0;
    }

    // Debounce mention search to avoid running regex on every keystroke
    if (SettingsSvc.settings.enablePrivateAPI.value && !subject && newEmojiText.contains("@")) {
      localController.debounceMentionSearch?.cancel();
      localController.debounceMentionSearch = Timer(const Duration(milliseconds: 150), () {
        TextFieldMatchHelper.processMentionMatches(controller, _controller, subject);
      });
    } else {
      localController.debounceMentionSearch?.cancel();
      controller.mentionMatches.value = [];
      controller.mentionSelectedIndex.value = 0;
    }
  }

  @override
  void dispose() {
    controller.logicalDraftConsumedFunc = null;
    final draftText = controller.textController.text.trim().isNotEmpty ? controller.textController.text : '';
    final draftAttachments = controller.pickedAttachments.where((e) => e.path != null).map((e) => e.path!).toList();
    if (_canMutateComposer && _hasLogicalDraftIdentity) {
      if (!_logicalDraftConsumed) {
        final logicalReply = _logicalReplyIntent();
        final subject = controller.subjectTextController.text;
        unawaited(
          ChatsSvc.saveLogicalSendIntent(
            chat,
            text: draftText,
            subject: subject,
            attachments: controller.pickedAttachments.toList(),
            reply: logicalReply,
            effectId: _retainedLogicalEffectId,
            expectedDraftGeneration: ChatsSvc.logicalDraftGenerationFor(chat),
          ),
        );
      }
    } else if (!_isProtectedLogicalSource) {
      // Update ChatState synchronously and fire DB save in the background.
      unawaited(ChatsSvc.setChatTextFieldText(chat, draftText));
      unawaited(ChatsSvc.setChatTextFieldAttachments(chat, draftAttachments));
    }

    controller.focusNode.dispose();
    controller.subjectFocusNode.dispose();
    controller.textController.dispose();
    controller.subjectTextController.dispose();
    recorderController?.dispose();
    _emojiScrollController.dispose();
    _logicalAttachmentDraftWorker?.dispose();
    _logicalReplyDraftWorker?.dispose();
    controller.showAttachmentPicker.value = false;
    localController.cancelAllTimers();
    Get.delete<ConversationTextFieldLocalController>();
    if (canDispatchOutboundTyping(isProtectedLogicalSource: _isProtectedLogicalSource) &&
        (chat.autoSendTypingIndicators ?? SettingsSvc.settings.privateSendTypingIndicators.value)) {
      unawaited(TypingIndicatorSvc.stopTyping(chatGuid));
    }

    super.dispose();
  }

  Future<void> sendMessage({String? effect}) {
    if (_confirmationFailed.value || _confirmationBusy.value || ChatsSvc.isLogicalDraftConfirmationInFlight(chat)) {
      return Future<void>.value();
    }
    final existing = _sendInFlight;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _sendMessageOnce(effect: effect).whenComplete(() {
      if (identical(_sendInFlight, operation)) _sendInFlight = null;
    });
    _sendInFlight = operation;
    return operation;
  }

  Future<void> _sendMessageOnce({String? effect}) async {
    effect ??= _retainedLogicalEffectId;
    try {
      if (_isProtectedLogicalSource && !_hasLogicalWriterCapability) {
        showSnackbar('Send unavailable', 'This conversation is read-only while its identity is being verified.');
        return;
      }
      if (_hasLogicalDraftIdentity) {
        final metadata = ChatsSvc.logicalDraftMetadataClassFor(chat);
        if (metadata == LogicalDraftMetadataClass.legacyUnboundDraft ||
            metadata == LogicalDraftMetadataClass.partiallyBoundInvalidDraft) {
          _refreshDraftConfirmationState();
          showSnackbar(
            'Send paused',
            metadata == LogicalDraftMetadataClass.legacyUnboundDraft
                ? 'Review and confirm this draft before a separate Send tap.'
                : 'This draft has inconsistent safety information. Your draft was preserved.',
          );
          return;
        }
      }
      final text = controller.textController.text;
      if (_logicalReplyResolutionPending.value ||
          !logicalReplyExecutionReady(
            intent: _retainedLogicalReplyIntent,
            exactTargetVisible: controller.replyToMessage != null,
          )) {
        showSnackbar('Reply unavailable', 'The reply target is still loading. Your draft was preserved.');
        return;
      }
      final subject = controller.subjectTextController.text;
      final replyIntent = _logicalReplyIntent();
      final replyGuid =
          replyIntent?.relationshipTargetGuid ??
          controller.replyToMessage?.message.threadOriginatorGuid ??
          controller.replyToMessage?.message.guid;
      final replyPart = replyIntent?.part ?? controller.replyToMessage?.partIndex;
      final attachments = controller.pickedAttachments.map(_freezeAttachment).toList(growable: false);
      final intentEpoch = _logicalIntentEpoch;
      final logicalOwner = ChatsSvc.conversationKeyFor(chat);
      final ownerController = controller;
      final selectedAtFreeze = controller.pickedAttachments.toList(growable: false);
      final originalPaths = selectedAtFreeze.map((file) => file.path).toList(growable: false);
      final replyFingerprint = logicalActionIdentity('reply', <Object?>[replyIntent?.toJson()]);
      String? composerChange() {
        if (!mounted || !identical(controller, ownerController)) return 'OWNER_CHANGED';
        if (ChatsSvc.conversationKeyFor(chat) != logicalOwner) return 'DRAFT_IDENTITY_CHANGED';
        if (controller.textController.text != text || controller.subjectTextController.text != subject) {
          return 'CONTENT_CHANGED';
        }
        if (logicalActionIdentity('reply', <Object?>[_logicalReplyIntent()?.toJson()]) != replyFingerprint) {
          return 'CONTENT_CHANGED';
        }
        final current = controller.pickedAttachments;
        if (current.length != attachments.length) return 'ATTACHMENT_INTENT_CHANGED';
        for (var index = 0; index < current.length; index++) {
          final selected = current[index];
          final frozen = attachments[index];
          if (selected.name != frozen.name ||
              selected.size != frozen.size ||
              selected.balloonBundleId != frozen.balloonBundleId ||
              !identical(selected, selectedAtFreeze[index])) {
            return 'ATTACHMENT_INTENT_CHANGED';
          }
          final stagedInternally = identical(selected, selectedAtFreeze[index]) && selected.path == frozen.path;
          if (selected.path != originalPaths[index] && !stagedInternally) return 'ATTACHMENT_INTENT_CHANGED';
        }
        return null;
      }

      _frozenComposerCurrent = () => composerChange() == null;
      localController.debounceDraftSave?.cancel();
      if (controller.scheduledDate.value != null) {
        if (_isProtectedLogicalSource) {
          return showSnackbar('Scheduling unavailable', 'Scheduling is unavailable for this protected conversation.');
        }
        final date = controller.scheduledDate.value!;
        if (date.isBefore(DateTime.now())) return showSnackbar("Error", "Pick a date in the future!");
        if (text.contains(MentionTextEditingController.escapingChar)) {
          return showSnackbar("Error", "Mentions are not allowed in scheduled messages!");
        }
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
              title: Text("Scheduling message...", style: context.theme.textTheme.titleLarge),
              content: SizedBox(
                height: 70,
                child: Center(
                  child: CircularProgressIndicator(
                    backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(context.theme.colorScheme.primary),
                  ),
                ),
              ),
            );
          },
        );
        // Revalidate at the last synchronous boundary. The conversation may
        // have entered quarantine (or the certificate ledger may have failed)
        // after the scheduling UI was admitted.
        if (_isProtectedLogicalSource) {
          if (mounted) Navigator.of(context).pop();
          return showSnackbar('Scheduling unavailable', 'Scheduling is unavailable for this protected conversation.');
        }
        final response = await HttpSvc.message.createScheduled(chat.guid, text, date.toUtc(), {"type": "once"});
        if (!mounted) return;
        Navigator.of(context).pop();
        if (response.statusCode == 200 && response.data != null) {
          showSnackbar("Notice", "Message scheduled successfully for ${buildFullDate(date)}");
        } else {
          Logger.error("Scheduled message error: ${response.statusCode}");
          Logger.error(response.data);
          showSnackbar("Error", "Something went wrong!");
        }
      } else {
        if (text.isEmpty && subject.isEmpty && !SettingsSvc.settings.privateAPIAttachmentSend.value) {
          if (controller.replyToMessage != null) {
            return showSnackbar("Error", "Turn on Private API Attachment Send to send replies with media!");
          } else if (effect != null) {
            return showSnackbar("Error", "Turn on Private API Attachment Send to send effects with media!");
          }
        }
        if (effect == null && SettingsSvc.settings.enablePrivateAPI.value) {
          final cleansed = text.replaceAll("!", "").toLowerCase();
          switch (cleansed) {
            case "congratulations":
            case "congrats":
              effect = effectMap["confetti"];
              break;
            case "happy birthday":
              effect = effectMap["balloons"];
              break;
            case "happy new year":
              effect = effectMap["fireworks"];
              break;
            case "happy chinese new year":
            case "happy lunar new year":
              effect = effectMap["celebration"];
              break;
            case "pew pew":
              effect = effectMap["lasers"];
              break;
          }
        }
        _admissionEffect = effect;
        final generationBefore = ChatsSvc.logicalDraftGenerationFor(chat);
        final authorityBefore = ChatsSvc.currentLogicalAuthorityRevision;
        final operationFingerprint = logicalActionIdentity('human-tap', <Object?>[
          logicalOwner,
          DateTime.now().microsecondsSinceEpoch,
          identityHashCode(this),
        ]);
        var diagnosticCount = 0;
        var lastDiagnosticResult = 'FREEZE_STARTED';
        LogicalDraft? frozenDraft;
        String selectionFingerprint(List<PlatformFile> selection) => logicalActionIdentity(
          'attachment-selection',
          selection.map((file) => <Object?>[identityHashCode(file), file.name, file.size, file.balloonBundleId]),
        );
        final attachmentSelectionBefore = selectionFingerprint(selectedAtFreeze);
        void record(String result, bool started) {
          final terminal = result.startsWith('FINAL_');
          if (!terminal) lastDiagnosticResult = result;
          if (!terminal && diagnosticCount++ >= 8) return;
          final current = ChatsSvc.loadLogicalDraft(chat);
          final revision = ChatsSvc.currentLogicalAuthorityRevision;
          final entry = <String, Object?>{
            'schema': 'LOGICAL_DRAFT_ADMISSION_DIAGNOSTIC_V1',
            'operation': operationFingerprint,
            'logical': logicalActionIdentity('logical', <Object?>[logicalOwner]),
            'draft': frozenDraft?.actionId,
            'contentBefore': frozenDraft?.contentFingerprint,
            'contentFinal': current?.contentFingerprint,
            'composerContentBefore': logicalActionIdentity('composer', <Object?>[text, subject, replyFingerprint]),
            'composerContentFinal': mounted
                ? logicalActionIdentity('composer', <Object?>[
                    controller.textController.text,
                    controller.subjectTextController.text,
                    logicalActionIdentity('reply', <Object?>[_logicalReplyIntent()?.toJson()]),
                  ])
                : null,
            'attachmentSelectionBefore': attachmentSelectionBefore,
            'attachmentSelectionFinal': mounted ? selectionFingerprint(controller.pickedAttachments) : null,
            'internalTransition': ChatsSvc.logicalDraftGenerationFor(chat) == generationBefore
                ? 'NO_SEMANTIC_CHANGE'
                : (_activeIntentGuard?.draftWasConsumed == true && started
                      ? 'GENERATION_CHANGED_EXPECTED_INTERNAL'
                      : 'GENERATION_CHANGED_EXTERNAL'),
            'draftState': current == null
                ? (_activeIntentGuard?.draftWasConsumed == true ? 'DRAFT_CONSUMED' : 'DRAFT_DISAPPEARED')
                : 'PRESENT',
            'generationBefore': generationBefore,
            'generationFinal': ChatsSvc.logicalDraftGenerationFor(chat),
            'authorityEpochAtFreeze': authorityBefore?.epoch,
            'draftAuthorityEpochBefore': frozenDraft?.observedAuthorityEpoch,
            'draftAuthorityEpochFinal': current?.observedAuthorityEpoch,
            'authorityEpochFinal': revision?.epoch,
            'authorityBefore': authorityBefore?.authorityRevision,
            'authorityFinal': revision?.authorityRevision,
            'certificateBefore': authorityBefore?.certificateRevision,
            'certificateFinal': revision?.certificateRevision,
            'result': result,
            'providerRequestStarted': started,
            'physicalExecutionProven': false,
          };
          for (final frame in logicalDraftDiagnosticFrames(entry)) {
            Logger.info(frame, tag: 'LogicalDraftAdmission');
            debugPrint(frame);
          }
        }

        _finalAdmissionDiagnostic = () =>
            record('FINAL_$lastDiagnosticResult', _activeIntentGuard?.providerRequestStarted ?? false);
        final logicalDraft = await _saveLogicalDraft(
          effectId: effect,
          useFrozenIntent: true,
          frozenText: text,
          frozenSubject: subject,
          frozenAttachments: attachments,
          frozenReply: replyIntent,
        );
        frozenDraft = logicalDraft;
        if (ChatsSvc.isLogicalConversation(chat) && logicalDraft == null) {
          record(_logicalDraftConsumed ? 'DRAFT_CONSUMED' : 'GENERATION_CHANGED_EXTERNAL', false);
          showSnackbar('Send paused', 'Draft changed. Review and send again.');
          return;
        }
        if (logicalDraft?.attachments.any((attachment) => !attachment.isRestorable) == true) {
          record('ATTACHMENT_INTENT_UNAVAILABLE', false);
          showSnackbar('Send blocked', 'One or more attachments are no longer available. Your draft was preserved.');
          return;
        }
        if (logicalDraft != null) {
          late final LogicalDraftIntentGuard intentGuard;
          intentGuard = LogicalDraftIntentGuard(
            frozenDraft: logicalDraft,
            authorityAtFreeze: authorityBefore,
            composerIsCurrent: () => composerChange() == null,
            validateCurrent: () {
              final change = composerChange();
              if (change != null) return change;
              if (ChatsSvc.logicalDraftGenerationFor(chat) != generationBefore) return 'GENERATION_CHANGED_EXTERNAL';
              final current = ChatsSvc.loadLogicalDraft(chat);
              if (current == null) return 'DRAFT_DISAPPEARED';
              if (current.logicalId != logicalDraft.logicalId ||
                  current.createdAtEpochMilliseconds != logicalDraft.createdAtEpochMilliseconds) {
                return 'DRAFT_IDENTITY_CHANGED';
              }
              if (logicalActionIdentity('attachments', current.attachments.map((item) => item.toJson())) !=
                  logicalActionIdentity('attachments', logicalDraft.attachments.map((item) => item.toJson()))) {
                return 'ATTACHMENT_INTENT_CHANGED';
              }
              if (current.contentFingerprint != logicalDraft.contentFingerprint) return 'CONTENT_CHANGED';
              if (current.actionId != logicalDraft.actionId) return 'DRAFT_IDENTITY_CHANGED';
              return null;
            },
            validateAuthority: () {
              final expected = intentGuard.effectiveDraft!;
              final revision = ChatsSvc.currentLogicalAuthorityRevision;
              if (revision?.certificateRevision != expected.observedCertificateRevision) {
                return 'CERTIFICATE_CHANGED';
              }
              if (revision?.authorityRevision != expected.observedAuthorityRevision ||
                  revision?.epoch != expected.observedAuthorityEpoch ||
                  (authorityBefore != null &&
                      (revision?.certificateRevision != authorityBefore.certificateRevision ||
                          revision?.authorityRevision != authorityBefore.authorityRevision ||
                          revision?.epoch != authorityBefore.epoch))) {
                return 'AUTHORITY_CHANGED';
              }
              return null;
            },
            record: record,
          );
          _activeIntentGuard = intentGuard;
        }
        try {
          _activeIntentGuard?.check();
          await controller.send(
            SendData(
              attachments: attachments,
              text: text,
              subject: subject,
              replyGuid: replyGuid,
              replyPart: replyPart,
              effectId: effect,
              logicalDraft: logicalDraft,
              logicalIntentGuard: _activeIntentGuard,
            ),
          );
        } on LogicalDraftIntentException catch (error) {
          if (mounted) {
            await _saveLogicalDraft();
            showSnackbar(
              'Send paused',
              error.reason == 'AUTHORITY_CHANGED' || error.reason == 'CERTIFICATE_CHANGED'
                  ? 'Conversation route changed. Review and send again.'
                  : 'Draft changed. Review and send again.',
            );
          }
          return;
        } on LogicalSendAdmissionException catch (error) {
          record('BLOCKED_${error.state.name}', _activeIntentGuard?.providerRequestStarted ?? false);
          if (mounted) showSnackbar('Send paused', logicalSendAdmissionUserMessage(error.state));
          return;
        }
        if (logicalDraft != null) record('COMPLETED', _activeIntentGuard?.providerRequestStarted ?? false);
        if (logicalDraft != null && composerChange() != null) {
          _logicalDraftConsumed = false;
          if (mounted) await _saveLogicalDraft();
          return;
        }
        if (logicalDraft != null && !_logicalDraftConsumed) {
          if (_logicalIntentEpoch != intentEpoch) {
            await _saveLogicalDraft();
            return;
          }
          final cleared = await ChatsSvc.clearLogicalDraftIfCurrent(_activeIntentGuard?.effectiveDraft ?? logicalDraft);
          if (!cleared) return;
          _activeIntentGuard?.draftConsumed();
          if (composerChange() != null) {
            _logicalDraftConsumed = false;
            if (mounted) await _saveLogicalDraft();
            return;
          }
          _logicalDraftConsumed = true;
          _retainedLogicalEffectId = null;
          localController.debounceDraftSave?.cancel();
        }
      }
      controller.pickedAttachments.clear();
      controller.textController.clear();
      controller.subjectTextController.clear();
      controller.replyToMessage = null;
      controller.scheduledDate.value = null;
      localController.debounceTyping = null;
      if (!_isProtectedLogicalSource) {
        // Clear the ordinary physical-chat draft after queue custody.
        unawaited(ChatsSvc.setChatTextFieldText(chat, ''));
        unawaited(ChatsSvc.setChatTextFieldAttachments(chat, []));
      }
    } on StateError catch (error) {
      if (error.message.toString().startsWith('LOGICAL_DRAFT_')) {
        Logger.warn('Logical draft custody blocked; persisted slots preserved', tag: 'LogicalDraftAdmission');
        if (mounted) showSnackbar('Send paused', 'Draft storage needs review. Your draft was kept.');
      } else {
        rethrow;
      }
    } finally {
      _finalAdmissionDiagnostic?.call();
      _finalAdmissionDiagnostic = null;
      _activeIntentGuard?.close();
      _activeIntentGuard = null;
      _frozenComposerCurrent = null;
      _admissionEffect = null;
    }
  }

  Future<void> openFullCamera({String type = 'camera'}) async {
    bool granted = (await Permission.camera.request()).isGranted;
    if (!granted) {
      showSnackbar("Error", "Camera access was denied!");
      return;
    }

    if (type == 'video') {
      final micGranted = (await Permission.microphone.request()).isGranted;
      if (!micGranted) {
        showSnackbar("Error", "Microphone access was denied!");
        return;
      }
    }

    final XFile? file;
    if (type == 'video') {
      file = await ImagePicker().pickVideo(source: ImageSource.camera);
    } else {
      file = await ImagePicker().pickImage(source: ImageSource.camera);
    }

    if (file != null) {
      controller.pickedAttachments.add(
        PlatformFile(
          path: file.path,
          name: file.path.split('/').last,
          size: await file.length(),
          bytes: await file.readAsBytes(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !_canMutateComposer,
      child: Obx(
        () => Padding(
          padding: EdgeInsets.only(bottom: showAttachmentPicker ? 0 : 10.0, top: 10.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LogicalDraftConfirmationBanner(
                metadataClass:
                    _confirmationFailed.value && _draftMetadataClass.value == LogicalDraftMetadataClass.modernBoundDraft
                    ? LogicalDraftMetadataClass.partiallyBoundInvalidDraft
                    : _draftMetadataClass.value,
                previouslyConfirmed: _legacyConfirmationPresent.value,
                busy: _confirmationBusy.value,
                onConfirm: () => unawaited(_reviewAndConfirmDraft()),
              ),
              if (_logicalReplyResolutionPending.value)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.reply_all_outlined, size: 18),
                  title: const Text(
                    'Reply target unavailable — draft preserved',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      _retainedLogicalReplyIntent = null;
                      _logicalReplyResolutionPending.value = false;
                      _logicalIntentEpoch += 1;
                      unawaited(_saveLogicalDraft());
                    },
                    child: const Text('Remove reply'),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  TextFieldIconBar(controller: controller, localController: localController),
                  Expanded(
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      clipBehavior: Clip.none,
                      children: [
                        TextFieldComponent(
                          key: controller.textFieldKey,
                          subjectTextController: controller.subjectTextController,
                          textController: controller.textController,
                          controller: controller,
                          recorderController: recorderController,
                          sendMessage: sendMessage,
                        ),
                        if (!kIsWeb)
                          Positioned(
                            top: 0,
                            bottom: 0,
                            child: TextFieldRecordingOverlay(
                              controller: controller,
                              recorderController: recorderController,
                            ),
                          ),
                        SendAnimation(parentController: controller),
                      ],
                    ),
                  ),
                  if (iOS || material) const SizedBox(width: 10),
                  if (samsung)
                    Padding(
                      padding: const EdgeInsets.only(right: 5.0),
                      child: TextFieldSuffix(
                        subjectTextController: controller.subjectTextController,
                        textController: controller.textController,
                        controller: controller,
                        recorderController: recorderController,
                        sendMessage: sendMessage,
                      ),
                    ),
                ],
              ),
              Builder(
                builder: (context) {
                  // Capture width outside the Obx lambda so the reactive builder does not
                  // register a MediaQuery.of dependency and rebuild on keyboard animation frames.
                  // sizeOf only notifies on actual display-size changes (rotation / resize).
                  final pickerWidth = MediaQuery.sizeOf(context).width;
                  return Obx(
                    () => AnimatedSize(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeIn,
                      alignment: Alignment.bottomCenter,
                      child: !showAttachmentPicker
                          ? SizedBox(width: pickerWidth)
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(height: 8),
                                AttachmentPicker(controller: controller),
                              ],
                            ),
                    ),
                  );
                },
              ),
              TextFieldEmojiPickerSection(
                controller: controller,
                proxyController: proxyController,
                emojiScrollController: _emojiScrollController,
                emojiPickerHeight: emojiPickerHeight,
                emojiColumns: emojiColumns,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
