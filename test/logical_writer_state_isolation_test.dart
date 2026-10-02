import 'package:bluebubbles/app/layouts/conversation_view/pages/conversation_view.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/ui/chat/chats_service.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _WriterPolicyChatsService extends ChatsService {
  _WriterPolicyChatsService(this.capability, {this.revision});

  final LogicalWriterCapability capability;
  final LogicalAuthorityRevision? revision;

  @override
  LogicalWriterCapability logicalWriterCapabilityFor(Chat chat) => capability;

  @override
  bool isApprovedLogicalSource(Chat chat) => capability != LogicalWriterCapability.ordinary;

  @override
  LogicalAuthorityRevision? get currentLogicalAuthorityRevision => revision;
}

Chat _chat(String guid) => Chat(guid: guid, chatIdentifier: guid, style: 43);

void main() {
  group('logical writer capability classification', () {
    test('certified read identity does not imply Build 99 writer capability', () {
      expect(
        classifyLogicalWriterCapability(isCertified: true, hasBuild99WriterBinding: false),
        LogicalWriterCapability.certifiedReadOnly,
      );
      expect(
        classifyLogicalWriterCapability(isCertified: true, hasBuild99WriterBinding: true),
        LogicalWriterCapability.build99Writer,
      );
      expect(
        classifyLogicalWriterCapability(isCertified: false, hasBuild99WriterBinding: true),
        LogicalWriterCapability.ordinary,
      );
    });
  });

  group('global Build 99 writer state isolation', () {
    const revision = LogicalAuthorityRevision(
      certificateRevision: 'banked-certificate',
      authorityRevision: 'banked-authority',
      epoch: 7,
    );

    test('certified read-only conversation cannot observe or mutate banked status', () async {
      final service = _WriterPolicyChatsService(LogicalWriterCapability.certifiedReadOnly, revision: revision);
      final chat = _chat('certified-read-only');
      service.logicalRouteRuntimeStatus.value = const LogicalRouteRuntimeStatus(
        stage: LogicalRouteRuntimeStage.qualified,
        reason: 'BANKED_SENTINEL',
        targetRowId: 99,
      );

      final scoped = service.logicalRouteRuntimeStatusFor(chat);
      expect(scoped.stage, LogicalRouteRuntimeStage.routeNotProven);
      expect(scoped.reason, 'CERTIFIED_LOGICAL_WRITE_UNAVAILABLE');
      expect(service.logicalWriterAuthorityRevisionFor(chat), isNull);
      expect(service.logicalProjectionAuthorityRevisionFor(chat), 'CERTIFIED_READ_ONLY_NO_WRITER_AUTHORITY');
      expect(service.publishBuild99WriterBlocked(chat, 'SHOULD_NOT_ESCAPE'), isFalse);
      expect(service.logicalRouteRuntimeStatus.value.reason, 'BANKED_SENTINEL');

      final result = await service.resolveLogicalMutationBatch(chat, const <LogicalMutationRequest>[
        LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage),
      ]);
      expect(result.decisions.single.reason, 'CERTIFIED_LOGICAL_WRITE_UNAVAILABLE');
      expect(result.revision, isNull);
      expect(service.logicalRouteRuntimeStatus.value.reason, 'BANKED_SENTINEL');
    });

    test('Build 99 writer conversation retains the banked state boundary', () {
      final service = _WriterPolicyChatsService(LogicalWriterCapability.build99Writer, revision: revision);
      final chat = _chat('banked-writer');

      expect(service.logicalWriterAuthorityRevisionFor(chat), same(revision));
      expect(service.logicalProjectionAuthorityRevisionFor(chat), revision.authorityRevision);
      expect(service.publishBuild99WriterBlocked(chat, 'BANKED_BLOCK'), isTrue);
      expect(service.logicalRouteRuntimeStatus.value.reason, 'BANKED_BLOCK');
      expect(service.logicalRouteRuntimeStatusFor(chat), same(service.logicalRouteRuntimeStatus.value));
    });
  });

  testWidgets('certified read-only writer surface is bounded and has no composer', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CertifiedLogicalWriteUnavailableBanner())));

    expect(find.text('Sending unavailable — this certified conversation is read-only'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
