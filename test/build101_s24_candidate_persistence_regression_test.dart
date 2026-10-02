import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';
import 'package:flutter_test/flutter_test.dart';

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
