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
  });
}
