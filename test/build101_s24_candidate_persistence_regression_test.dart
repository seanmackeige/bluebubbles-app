import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/helpers/types/helpers/message_helper.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  group('Build 101 S24 candidate persistence feedback regression', () {
    test('banks the privacy-safe real-device failure shape', () {
      final fixture =
          (jsonDecode(File('test/fixtures/build101_s24_candidate_persistence_feedback.json').readAsStringSync()) as Map)
              .cast<String, dynamic>();
      final reproduction = (fixture['controlledReproduction'] as Map).cast<String, dynamic>();

      expect(fixture['historicalAnrCount'], 5);
      expect(fixture['exitReason'], 'ANR_INPUT_DISPATCH_TIMEOUT');
      expect(fixture['mainThreadState'], 'RUNNABLE_DART_AOT');
      expect(reproduction['sampledCpuPercentPeak'], greaterThan(100));
      expect(reproduction['stableUiReached'], isFalse);
      expect(fixture['firstBrokenTransition'], 'CONVERSATION_LIST_TO_CANDIDATE_PERSISTENCE_SIDE_EFFECTS');
    });

    test('banks the Build 103 S24 contact-to-list rebuild storm', () {
      final fixture =
          (jsonDecode(File('test/fixtures/build103_s24_contact_logical_projection_storm.json').readAsStringSync())
                  as Map)
              .cast<String, dynamic>();
      final provider = (fixture['contentProviderOperations'] as Map).cast<String, dynamic>();

      expect(fixture['exitReason'], 'ANR_INPUT_DISPATCH_TIMEOUT');
      expect(fixture['mainThreadState'], 'DART_UI_WIDGET_REBUILD');
      expect(fixture['mainThreadCpuMs'], greaterThan(10000));
      expect(provider['queries'], 621);
      expect(provider['opens'], 450);
      expect(fixture['containsPersonalContent'], isFalse);
    });

    test('banks the Build 104 exact-S24 touch-triggered stretch shader ANR', () {
      final fixture =
          (jsonDecode(File('test/fixtures/build104_s24_touch_stretch_shader_anr.json').readAsStringSync()) as Map)
              .cast<String, dynamic>();
      final trigger = (fixture['trigger'] as Map).cast<String, dynamic>();
      final resources = (fixture['resourceEvidence'] as Map).cast<String, dynamic>();
      final stack = (fixture['mainThreadStack'] as List).cast<String>();

      expect(trigger['kind'], 'single foreground touch');
      expect(trigger['failedWithoutTouch'], isFalse);
      expect(fixture['exitReason'], 'ANR_INPUT_DISPATCH_TIMEOUT');
      expect(fixture['firstBrokenTransition'], 'TOUCH_TO_SHADER_STRETCH_FRAME');
      expect(
        stack,
        containsAllInOrder(<String>[
          'ListBase.removeWhere',
          'FragmentProgram.fragmentShader',
          '_StretchOverscrollEffectState.build',
        ]),
      );
      expect(resources['anrCpuPercent'], greaterThan(100));
      expect(resources['sampledRssPeakKb'], greaterThan(500000));
      expect(fixture['containsPersonalContent'], isFalse);
    });

    test('banks the Build 105 exact-S24 pre-input message emoji ANR', () {
      final fixture =
          (jsonDecode(File('test/fixtures/build105_s24_touch_message_emoji_anr.json').readAsStringSync()) as Map)
              .cast<String, dynamic>();
      final trigger = (fixture['trigger'] as Map).cast<String, dynamic>();
      final resources = (fixture['resourceEvidence'] as Map).cast<String, dynamic>();
      final stack = (fixture['mainThreadStack'] as List).cast<String>();

      expect(fixture['versionCode'], 20002105);
      expect(trigger['kind'], 'foreground MotionEvent input deadline');
      expect(trigger['role'], 'ANR_DETECTOR_NOT_PROVEN_WORKLOAD_INITIATOR');
      expect(trigger['inputTimeoutMs'], 10000);
      expect(fixture['exitReason'], 'ANR_INPUT_DISPATCH_TIMEOUT');
      expect(fixture['firstBrokenTransition'], 'CONVERSATION_TIMELINE_LAYOUT_TO_UNBOUNDED_MESSAGE_EMOJI_REGEXP');
      expect(
        stack,
        containsAllInOrder(<String>[
          '_RegExp._ExecuteMatch',
          '_RegExp.firstMatch',
          'MessageHelper.shouldShowBigEmoji',
          'Message.isBigEmoji',
          '_TextBubbleState.build',
        ]),
      );
      expect((resources['preInputCpuSamplesPercent'] as List).first, greaterThan(100));
      expect(resources['instantProcessCpuPercent'], 100);
      expect(resources['rssKb'], greaterThan(400000));
      expect(fixture['containsPersonalContent'], isFalse);
    });

    test('big-emoji classification never applies the global regexp to a complete message', () {
      final source = File('lib/helpers/types/helpers/message_helper.dart').readAsStringSync();
      final method = source.substring(
        source.indexOf('static bool shouldShowBigEmoji'),
        source.indexOf('static List<TextSpan> buildEmojiText'),
      );

      expect(method, contains('for (final grapheme in candidate.characters)'));
      expect(method, contains('candidate.length > _maxBigEmojiCandidateCodeUnits'));
      expect(method, contains('grapheme.length > _maxBigEmojiGraphemeCodeUnits'));
      expect(method, contains('emojiRegex.allMatches(grapheme)'));
      expect(
        method.indexOf('candidate.length > _maxBigEmojiCandidateCodeUnits'),
        lessThan(method.indexOf('for (final grapheme in candidate.characters)')),
      );
      expect(method, isNot(contains('emojiRegex.firstMatch(candidate)')));
      expect(method, isNot(contains('emojiRegex.allMatches(candidate)')));
    });

    test('big-emoji classification is bounded for runtime-shaped long messages', () {
      final longMessage = '${List.filled(200000, 'a').join()}\u{1F600}';
      final stopwatch = Stopwatch()..start();

      expect(MessageHelper.shouldShowBigEmoji(longMessage), isFalse);
      stopwatch.stop();

      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      expect(MessageHelper.shouldShowBigEmoji(' \u{1F600} '), isTrue);
      expect(MessageHelper.shouldShowBigEmoji('\u{1F600}\u{1F600}\u{1F600}'), isTrue);
      expect(MessageHelper.shouldShowBigEmoji('\u{1F600}\u{1F600}\u{1F600}\u{1F600}'), isFalse);
      expect(MessageHelper.shouldShowBigEmoji('${List.filled(200000, '\u0301').join()}\u{1F600}'), isFalse);
      expect(MessageHelper.shouldShowBigEmoji(List.filled(64, '\u0301').join()), isFalse);
      expect(MessageHelper.shouldShowBigEmoji(List.filled(65, '\u0301').join()), isFalse);
    });

    test('timeline emoji rendering never applies its generated regexp to a complete message', () {
      final source = File('lib/helpers/types/helpers/message_helper.dart').readAsStringSync();
      final method = source.substring(
        source.indexOf('static List<TextSpan> buildEmojiText'),
        source.indexOf('static void _appendEmojiTextChunk'),
      );
      final boundedHelper = source.substring(source.indexOf('static void _appendEmojiTextChunk'));

      expect(method, contains('text.length > _maxEmojiStyledTextCodeUnits'));
      expect(method, contains('for (final grapheme in text.characters)'));
      expect(method, contains('chunk.length + grapheme.length > _maxBigEmojiGraphemeCodeUnits'));
      expect(method, contains('_appendEmojiTextChunk(children, chunk.toString(), style, recognizer)'));
      expect(method, isNot(contains('_renderEmojiRegex.allMatches(text)')));
      expect(method, isNot(contains('emojiRegex.allMatches(text)')));
      expect(boundedHelper, contains('_renderEmojiRegex.allMatches(text)'));
    });

    test('bounded timeline rendering preserves text and emoji styling for ordinary messages', () {
      final ownedFilesystem = !GetIt.I.isRegistered<FilesystemService>();
      if (ownedFilesystem) GetIt.I.registerSingleton<FilesystemService>(FilesystemService());
      final previousFontState = FilesystemSvc.fontExistsOnDisk.value;
      FilesystemSvc.fontExistsOnDisk.value = true;

      try {
        const text = 'before \u{1F600}\u{1F600} after';
        final spans = MessageHelper.buildEmojiText(text, const TextStyle());
        expect(spans.map((span) => span.text).join(), text);
        expect(spans.any((span) => span.style?.fontFamily == 'Apple Color Emoji'), isTrue);

        final longText = '${List.filled(5000, 'a').join()}\u{1F600}';
        final fallback = MessageHelper.buildEmojiText(longText, const TextStyle());
        expect(fallback, hasLength(1));
        expect(fallback.single.text, longText);
        expect(fallback.single.style?.fontFamily, isNot('Apple Color Emoji'));

        final boundaryText = List.filled(4096, 'a').join();
        expect(
          MessageHelper.buildEmojiText(boundaryText, const TextStyle()).map((span) => span.text).join(),
          boundaryText,
        );
        final overBoundaryText = '${boundaryText}a';
        final overBoundary = MessageHelper.buildEmojiText(overBoundaryText, const TextStyle());
        expect(overBoundary, hasLength(1));
        expect(overBoundary.single.text, overBoundaryText);
      } finally {
        FilesystemSvc.fontExistsOnDisk.value = previousFontState;
        if (ownedFilesystem) GetIt.I.unregister<FilesystemService>();
      }
    });

    test('Android scroll behavior excludes the shader-backed stretch path', () {
      final source = File('lib/main.dart').readAsStringSync();
      final scrollBehavior = source.substring(
        source.indexOf('scrollBehavior: const MaterialScrollBehavior()'),
        source.indexOf('home: const Home()'),
      );

      expect(scrollBehavior, contains('overscroll: false'));
    });

    testWidgets('disabled overscroll decoration cannot construct a stretching indicator', (tester) async {
      const marker = Key('bounded-scroll-child');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, useMaterial3: true),
          home: Builder(
            builder: (context) => const MaterialScrollBehavior()
                .copyWith(overscroll: false)
                .buildOverscrollIndicator(
                  context,
                  const SizedBox(key: marker),
                  const ScrollableDetails(direction: AxisDirection.down),
                ),
          ),
        ),
      );

      expect(find.byKey(marker), findsOneWidget);
      expect(find.byType(StretchingOverscrollIndicator), findsNothing);
    });

    test('coalesces identical in-flight persistence and publishes only a real write', () {
      final coordinator = LogicalCandidatePersistenceCoordinator();

      expect(coordinator.isBusy, isFalse);
      expect(coordinator.request('changed'), isTrue);
      expect(coordinator.isBusy, isTrue);
      for (var projectionRead = 0; projectionRead < 5000; projectionRead++) {
        expect(coordinator.request('changed'), isFalse);
      }
      expect(coordinator.complete('changed', wrote: true), isTrue);
      expect(coordinator.isBusy, isFalse);
      expect(coordinator.complete('changed', wrote: false), isFalse);
      expect(coordinator.request('changed'), isTrue);
      expect(coordinator.complete('changed', wrote: false), isFalse);
    });

    test('keeps per-chat projection lookup free of persistence and hashing', () {
      final source = File('lib/services/ui/chat/chats_service.dart').readAsStringSync();
      final lookup = source.substring(
        source.indexOf('LogicalCandidateQuarantineRecord? _logicalCandidateRecordForChat'),
        source.indexOf('void _materializeLogicalCandidateQuarantine'),
      );
      final projection = source.substring(
        source.indexOf('List<Chat> _projectLogicalChatList'),
        source.indexOf('void _syncLogicalPresentationState'),
      );

      expect(lookup, isNot(contains('_scheduleLogicalCandidateQuarantinePersistence')));
      expect(lookup, isNot(contains('stableFingerprintAt')));
      expect('_materializeLogicalCandidateQuarantine'.allMatches(projection).length, 1);

      for (final boundary in <List<String>>[
        <String>['LogicalMutationProtection logicalMutationProtectionFor', 'bool isPotentialLogicalSource'],
        <String>['LogicalCandidateQuarantinePhase? logicalCandidateQuarantinePhaseFor', 'bool canApplyConversation'],
        <String>['bool _canAffectBuild99WriterAuthority', 'String? logicalConversationIdFor'],
      ]) {
        final readBoundary = source.substring(source.indexOf(boundary.first), source.indexOf(boundary.last));
        expect(readBoundary, isNot(contains('_materializeLogicalCandidateQuarantine')));
        expect(readBoundary, isNot(contains('stableFingerprintAt')));
      }
    });

    test('ordinary chat updates cannot refresh every logical presentation', () {
      final source = File('lib/services/ui/chat/chats_service.dart').readAsStringSync();
      final updateChat = source.substring(source.indexOf('bool updateChat('), source.indexOf('void updateChats('));
      final refreshCall = updateChat.indexOf('_refreshLogicalPresentation');
      final relevanceGuard = updateChat.indexOf('if (logicalPresentationRelevant)');

      expect(relevanceGuard, greaterThanOrEqualTo(0));
      expect(refreshCall, greaterThan(relevanceGuard));
      expect(updateChat, contains('_isLogicalPresentationRelevantUpdate(state.chat, updated)'));
    });
  });
}
