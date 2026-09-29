import 'dart:math';

import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:bluebubbles/services/ui/chat/logical_execution_authority.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/logical_runtime_fixture.dart';

const _newMessage = LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage);

// Runtime fixture coordinates (test data only; production logic never sees them).
const _predecessorRow = 2027;
const _selfVariantRow = 2155;
const _canonicalSmsRow = 2156;
const _naturalOutboundAt = 1790630949766;
const _naturalReactionAt = 1790632613250;
const _minute = 60 * 1000;

LogicalExecutionAuthority _authority(LogicalRouteEvidence evidence) =>
    LogicalConversationOutboundRoutePolicy.executionAuthority(evidence)!;

LogicalRouteDecision _resolve(LogicalRouteEvidence evidence, [LogicalMutationRequest request = _newMessage]) =>
    LogicalConversationOutboundRoutePolicy.resolve(evidence, request);

Map<String, dynamic> _msg(
  String guid,
  int rowId,
  int at, {
  bool fromMe = false,
  int error = 0,
  String? associated,
  String? thread,
}) => <String, dynamic>{
  'guid': guid,
  'rowId': rowId,
  'dateCreated': at,
  'isFromMe': fromMe,
  'error': error,
  'itemType': 0,
  'associatedMessageGuid': associated,
  'threadOriginatorGuid': thread,
};

LogicalRouteCandidateEvidence _copy(
  LogicalRouteCandidateEvidence candidate, {
  int? rowId,
  String? lastSeen,
  String? groupPhoto,
  String? groupId,
  bool? hybrid,
  bool? forceSms,
  List<LogicalRouteMessageEvidence>? messages,
  List<LogicalSuccessfulOutboundEvidence>? outbounds,
  LogicalProviderFactEvidence? sourceAccountFact,
  bool touchGroup = false,
}) => LogicalRouteCandidateEvidence(
  sourceChatRowId: rowId ?? candidate.sourceChatRowId,
  sourceChatGuid: candidate.sourceChatGuid,
  sourceService: candidate.sourceService,
  sourceAccount: candidate.sourceAccount,
  chatIdentifier: candidate.chatIdentifier,
  style: candidate.style,
  lastAddressedHandle: candidate.lastAddressedHandle,
  participants: candidate.participants,
  chatSnapshotComplete: candidate.chatSnapshotComplete,
  messageSnapshotComplete: candidate.messageSnapshotComplete,
  lastKnownHybridState: hybrid ?? candidate.lastKnownHybridState,
  shouldForceToSms: forceSms ?? candidate.shouldForceToSms,
  lastSeenMessageGuid: lastSeen ?? candidate.lastSeenMessageGuid,
  groupPhotoGuid: touchGroup ? groupPhoto : candidate.groupPhotoGuid,
  groupIdentifier: touchGroup ? groupId : candidate.groupIdentifier,
  messages: messages ?? candidate.messages,
  successfulOutbounds: outbounds ?? candidate.successfulOutbounds,
  sourceAccountFact: sourceAccountFact ?? candidate.sourceAccountFact,
);

LogicalRouteEvidence _withCandidates(LogicalRouteEvidence base, List<LogicalRouteCandidateEvidence> candidates) =>
    LogicalRouteEvidence(
      logicalId: base.logicalId,
      certificateId: base.certificateId,
      certifiedSourceChatGuids: {for (final candidate in candidates) candidate.sourceChatRowId: candidate.sourceChatGuid},
      backendComputerId: base.backendComputerId,
      detectedIMessage: base.detectedIMessage,
      privateApiConnected: base.privateApiConnected,
      helperConnected: base.helperConnected,
      accountSnapshotBeforeSha256: base.accountSnapshotBeforeSha256,
      accountSnapshotAfterSha256: base.accountSnapshotAfterSha256,
      activeSelfAlias: base.activeSelfAlias,
      vettedSelfAliases: base.vettedSelfAliases,
      executionGenerationCertificate: base.executionGenerationCertificate,
      candidateScopeSnapshotComplete: base.candidateScopeSnapshotComplete,
      unadmittedPotentialSourceChatGuids: base.unadmittedPotentialSourceChatGuids,
      candidates: candidates,
    );

/// A fixture-shaped new physical chat for the given service. Its GUID is
/// bound by the fixture certificate so account fallback applies exactly as it
/// would for an admitted member.
Map<String, dynamic> _newPhysicalChat(
  LogicalRuntimeFixture fixture, {
  required int rowId,
  required String service,
  required List<Map<String, dynamic>> messages,
}) {
  final template = fixture.chat(service == 'SMS' ? _canonicalSmsRow : _predecessorRow);
  return <String, dynamic>{
    ...template,
    'rowId': rowId,
    'guid': '$service;+;chat-new-generation-$rowId',
    'chatIdentifier': 'chat-new-generation-identifier-$rowId',
    'groupId': 'group-new-generation-$rowId',
    'groupPhotoGuid': null,
    'messages': messages,
  };
}

String _stableRevision(LogicalRouteEvidence evidence) {
  final authority = _authority(evidence);
  return '${evidence.authorityRevision}:${authority.revisionMaterial}';
}

void main() {
  final fixture = LogicalRuntimeFixture.load();

  group('runtime fixture: Comcast Node Updates natural sequence', () {
    test('A: current natural outbound and literal reaction converge on one SMS writer', () {
      final evidence = fixture.evidence();
      final authority = _authority(evidence);
      final decision = _resolve(evidence);
      expect(authority.state, LogicalExecutionAuthorityState.sendReady, reason: authority.blockingPredicate);
      expect(authority.writerRowId, _canonicalSmsRow);
      expect(decision.isSingleTarget, isTrue, reason: decision.reason);
      expect(decision.physicalTargetRowIds, [_canonicalSmsRow]);
      expect(decision.reason, LogicalExecutionConvergence.readyReason);

      final roles = {for (final member in authority.members) member.sourceChatRowId: member.role};
      expect(roles[_canonicalSmsRow], LogicalGenerationEdgeClass.currentExecutionAuthority);
      expect(roles[_selfVariantRow], LogicalGenerationEdgeClass.selfAliasVariant);
      expect(roles[_predecessorRow], LogicalGenerationEdgeClass.predecessor);
      final representation = {for (final member in authority.members) member.sourceChatRowId: member.representation};
      expect(representation[_selfVariantRow], LogicalGenerationRepresentation.selfAliasVariant);
      expect(representation[_canonicalSmsRow], LogicalGenerationRepresentation.canonicalRoute);
      final generation = {for (final member in authority.members) member.sourceChatRowId: member.generationId};
      expect(generation[_selfVariantRow], generation[_canonicalSmsRow], reason: '2155 and 2156 are one generation');
      expect(generation[_predecessorRow], isNot(generation[_canonicalSmsRow]));
      expect(authority.currentGenerationRowIds, [_selfVariantRow, _canonicalSmsRow]);
      expect(authority.memberEdges['$_canonicalSmsRow->$_selfVariantRow:SELF_ALIAS_VARIANT'], 18);
      expect(authority.memberEdges['$_canonicalSmsRow->$_predecessorRow:RELATIONSHIP_SOURCE_ONLY'], 2);
    });

    test('the literal SMS reaction is Tier-4 quoted text, never a structured edge', () {
      final reaction = fixture.message(159542);
      expect(reaction['literalReactionVerb'], 'Liked');
      expect(reaction['literalQuotedTargetGuid'], fixture.message(159539)['guid']);
      expect(reaction['associatedMessageGuid'], isNull);
      expect(reaction['threadOriginatorGuid'], isNull);
    });

    test('the natural outbound alone is enough: writer READY immediately after it', () {
      final authority = _authority(fixture.evidence(asOf: _naturalOutboundAt));
      expect(authority.isReady, isTrue, reason: authority.blockingPredicate);
      expect(authority.writerRowId, _canonicalSmsRow);
      expect(authority.frontierOutboundRowId, 159539);
    });

    test('replay: read-side events never flip authority and never change the writer', () {
      final start = DateTime.utc(2026, 8, 20).millisecondsSinceEpoch;
      final outboundTimes = <int>{
        for (final chat in fixture.chats)
          for (final message in (chat['messages'] as List).cast<Map>())
            if (message['isFromMe'] == true &&
                message['error'] == 0 &&
                message['itemType'] == 0 &&
                message['associatedMessageGuid'] == null)
              message['dateCreated'] as int,
      };
      LogicalExecutionAuthority? previous;
      String? previousRevision;
      var transitions = 0;
      var readyToBlockedOnReadSide = 0;
      var writerChangedOnReadSide = 0;
      var revisionChangedOnReadSideWhileReady = 0;
      for (final at in fixture.eventTimes.where((time) => time >= start)) {
        final evidence = fixture.evidence(asOf: at);
        final authority = _authority(evidence);
        final revision = _stableRevision(evidence);
        if (previous != null) {
          final readSide = !outboundTimes.contains(at);
          if (previous.state != authority.state || previous.writerRowId != authority.writerRowId) transitions += 1;
          if (readSide && previous.isReady && !authority.isReady) readyToBlockedOnReadSide += 1;
          if (readSide && previous.isReady && authority.writerRowId != previous.writerRowId) writerChangedOnReadSide += 1;
          if (readSide && previous.isReady && revision != previousRevision) revisionChangedOnReadSideWhileReady += 1;
        }
        previous = authority;
        previousRevision = revision;
      }
      expect(readyToBlockedOnReadSide, 0);
      expect(writerChangedOnReadSide, 0);
      expect(revisionChangedOnReadSideWhileReady, 0);
      expect(previous!.writerRowId, _canonicalSmsRow);
      expect(transitions, lessThan(20));
    });

    test('Sept 21 iMessage outbounds invalidate SMS until SMS execution is corroborated again', () {
      final imessageFrontier = fixture.message(158527)['dateCreated'] as int;
      final after = _authority(fixture.evidence(asOf: imessageFrontier));
      expect(after.state, LogicalExecutionAuthorityState.blockedNoCurrentWriter);
      expect(after.blockingPredicate, 'CURRENT_GENERATION_EXECUTION_UNCORROBORATED');
      expect(after.currentGenerationRowIds, [_predecessorRow]);
      final smsReturn = fixture.message(158840)['dateCreated'] as int;
      final corroborated = _authority(fixture.evidence(asOf: smsReturn + 2 * 60 * _minute));
      expect(corroborated.isReady, isTrue, reason: corroborated.blockingPredicate);
      expect(corroborated.writerRowId, _canonicalSmsRow);
    });

    test('event order independence: every candidate and message permutation yields one answer', () {
      final base = fixture.evidence();
      final expected = _resolve(base);
      final expectedRevision = _stableRevision(base);
      final random = Random(20260929);
      for (var iteration = 0; iteration < 12; iteration++) {
        final candidates = base.candidates
            .map((candidate) => _copy(candidate, messages: candidate.messages.toList()..shuffle(random)))
            .toList()
          ..shuffle(random);
        final permuted = _withCandidates(base, candidates);
        final decision = _resolve(permuted);
        expect(decision.reason, expected.reason);
        expect(decision.physicalTargetRowIds, expected.physicalTargetRowIds);
        expect(_stableRevision(permuted), expectedRevision);
      }
    });
  });

  group('regression bank A-L', () {
    test('B: read-only reconciliation keeps writer and authority revision byte-identical', () {
      final base = fixture.evidence();
      final baseRevision = _stableRevision(base);
      final reconciled = _withCandidates(base, [
        for (final candidate in base.candidates)
          _copy(
            candidate,
            lastSeen: candidate.messages.first.messageGuid,
            hybrid: candidate.lastKnownHybridState == null ? true : null,
            touchGroup: true,
            groupPhoto: 'photo-refreshed',
            groupId: 'group-refreshed-${candidate.sourceChatRowId}',
          ),
      ]);
      expect(_resolve(reconciled).physicalTargetRowIds, [_canonicalSmsRow]);
      expect(_stableRevision(reconciled), baseRevision);
    });

    test('C: natural structured and literal reactions in the self-alias variant keep READY', () {
      final target = fixture.message(159539)['guid'] as String;
      final evidence = fixture.evidence(
        extraMessages: {
          _selfVariantRow: [
            _msg('structured-like', 900001, _naturalReactionAt + _minute, associated: 'p:0/$target'),
            _msg('literal-like', 900002, _naturalReactionAt + 2 * _minute),
          ],
          _predecessorRow: [_msg('structured-like-in-predecessor', 900003, _naturalReactionAt + 3 * _minute,
              associated: 'p:0/$target')],
        },
      );
      expect(_resolve(evidence).physicalTargetRowIds, [_canonicalSmsRow]);
      expect(_stableRevision(evidence), _stableRevision(fixture.evidence()));
    });

    test('D: a present contradiction on any member blocks as an invariant', () {
      final base = fixture.evidence();
      final contradicted = _withCandidates(base, [
        for (final candidate in base.candidates)
          candidate.sourceChatRowId == _canonicalSmsRow
              ? _copy(
                  candidate,
                  outbounds: [
                    for (final outbound in candidate.successfulOutbounds)
                      outbound.messageRowId == 159539
                          ? LogicalSuccessfulOutboundEvidence(
                              messageGuid: outbound.messageGuid,
                              messageRowId: outbound.messageRowId,
                              createdAtEpoch: outbound.createdAtEpoch,
                              account: outbound.account,
                              accountFact: outbound.accountFact,
                              isSentFact: const LogicalProviderFactEvidence(
                                state: LogicalProviderFactState.presentAndContradicts,
                              ),
                            )
                          : outbound,
                  ],
                )
              : candidate,
      ]);
      final authority = _authority(contradicted);
      expect(authority.state, LogicalExecutionAuthorityState.blockedInvariant);
      expect(authority.blockingPredicate, 'AUTHORITATIVE_TERMINAL_FACT_CONTRADICTION');
      final wrongAccount = _withCandidates(base, [
        for (final candidate in base.candidates)
          candidate.sourceChatRowId == _selfVariantRow
              ? _copy(
                  candidate,
                  sourceAccountFact: const LogicalProviderFactEvidence(
                    state: LogicalProviderFactState.presentAndContradicts,
                  ),
                )
              : candidate,
      ]);
      expect(_resolve(wrongAccount).reason, 'AUTHORITATIVE_ACCOUNT_CONTRADICTION');
    });

    test('E: an unadmitted physical candidate with the same participants is never auto-enrolled', () {
      final evidence = fixture.evidence(unadmitted: const {4242: 'SMS;+;chat-unadmitted'});
      final authority = _authority(evidence);
      expect(authority.state, LogicalExecutionAuthorityState.blockedInvariant);
      expect(authority.blockingPredicate, 'UNADMITTED_POTENTIAL_EXECUTION_GENERATION_PRESENT');
    });

    test('F: a genuine corroborated new generation invalidates the old writer and establishes the new one', () {
      final newChat = _newPhysicalChat(
        fixture,
        rowId: 3100,
        service: 'iMessage',
        messages: [
          _msg('new-generation-outbound', 910001, _naturalReactionAt + 10 * _minute, fromMe: true),
          _msg('new-generation-reply', 910002, _naturalReactionAt + 12 * _minute),
        ],
      );
      final newAccountChat = <String, dynamic>{...newChat};
      final uncorroborated = _newPhysicalChat(
        fixture,
        rowId: 3100,
        service: 'iMessage',
        messages: [_msg('new-generation-outbound', 910001, _naturalReactionAt + 10 * _minute, fromMe: true)],
      );
      // Same iMessage account as 2027 means same generation; the newer
      // canonical representation wins by execution recency.
      final established = _authority(fixture.evidence(extraChats: [newAccountChat]));
      expect(established.isReady, isTrue, reason: established.blockingPredicate);
      expect(established.writerRowId, 3100);
      final roles = {for (final member in established.members) member.sourceChatRowId: member.role};
      expect(roles[_canonicalSmsRow], LogicalGenerationEdgeClass.predecessor);
      expect(roles[_predecessorRow], LogicalGenerationEdgeClass.currentExecutionCandidate);

      final pending = _authority(fixture.evidence(extraChats: [uncorroborated]));
      expect(pending.state, LogicalExecutionAuthorityState.blockedNoCurrentWriter);
      expect(pending.blockingPredicate, 'CURRENT_GENERATION_EXECUTION_UNCORROBORATED');
    });

    test('G: a late inbound on the predecessor never reclaims authority', () {
      final evidence = fixture.evidence(
        extraMessages: {
          _predecessorRow: [
            _msg('late-predecessor-inbound', 920001, _naturalReactionAt + _minute),
            _msg('late-predecessor-reply', 920002, _naturalReactionAt + 2 * _minute,
                thread: fixture.message(158527)['guid'] as String),
          ],
        },
      );
      expect(_resolve(evidence).physicalTargetRowIds, [_canonicalSmsRow]);
      expect(_stableRevision(evidence), _stableRevision(fixture.evidence()));
    });

    test('H: the successor sending and receiving retains the writer and its revision', () {
      final evidence = fixture.evidence(
        extraMessages: {
          _canonicalSmsRow: [
            _msg('successor-outbound', 930001, _naturalReactionAt + _minute, fromMe: true),
            _msg('successor-inbound', 930002, _naturalReactionAt + 2 * _minute),
          ],
          _selfVariantRow: [_msg('variant-inbound', 930003, _naturalReactionAt + 3 * _minute)],
        },
      );
      expect(_resolve(evidence).physicalTargetRowIds, [_canonicalSmsRow]);
      expect(_stableRevision(evidence), _stableRevision(fixture.evidence()));
    });

    test('I: official client sends are classified by generation, failures are ignored', () {
      final viaVariant = fixture.evidence(
        extraMessages: {
          _selfVariantRow: [_msg('official-variant-outbound', 940001, _naturalReactionAt + _minute, fromMe: true)],
        },
      );
      expect(_resolve(viaVariant).physicalTargetRowIds, [_canonicalSmsRow]);

      final failedPredecessor = fixture.evidence(
        extraMessages: {
          _predecessorRow: [
            _msg('official-failed-imessage', 940002, _naturalReactionAt + _minute, fromMe: true, error: 22),
          ],
        },
      );
      expect(_resolve(failedPredecessor).physicalTargetRowIds, [_canonicalSmsRow]);
      expect(_stableRevision(failedPredecessor), _stableRevision(fixture.evidence()));

      final acceptedPredecessor = fixture.evidence(
        extraMessages: {
          _predecessorRow: [_msg('official-imessage', 940003, _naturalReactionAt + _minute, fromMe: true)],
        },
      );
      final pending = _authority(acceptedPredecessor);
      expect(pending.state, LogicalExecutionAuthorityState.blockedNoCurrentWriter);
      expect(pending.currentGenerationRowIds, [_predecessorRow]);

      final corroboratedPredecessor = fixture.evidence(
        extraMessages: {
          _predecessorRow: [
            _msg('official-imessage', 940003, _naturalReactionAt + _minute, fromMe: true),
            _msg('imessage-tapback', 940004, _naturalReactionAt + 5 * _minute, associated: 'p:0/official-imessage'),
          ],
        },
      );
      final moved = _authority(corroboratedPredecessor);
      expect(moved.isReady, isTrue, reason: moved.blockingPredicate);
      expect(moved.writerRowId, _predecessorRow);
      expect(moved.generationEvidenceClass, LogicalExecutionCorroboration.structuredResponse);
    });

    test('J: repeated refresh and reconnect observations are identical', () {
      final revisions = <String>{};
      final decisions = <String>{};
      for (var index = 0; index < 50; index++) {
        final evidence = fixture.evidence();
        revisions.add(_stableRevision(evidence));
        final decision = _resolve(evidence);
        decisions.add('${decision.reason}:${decision.physicalTargetRowIds}');
      }
      expect(revisions, hasLength(1));
      expect(decisions, {'${LogicalExecutionConvergence.readyReason}:[$_canonicalSmsRow]'});
    });

    test('K: authority is a pure function of evidence and reconstructs without any cache', () {
      final first = _authority(fixture.evidence());
      final rebuilt = _authority(LogicalRuntimeFixture.load().evidence());
      expect(rebuilt.revisionMaterial, first.revisionMaterial);
      expect(rebuilt.writerRowId, first.writerRowId);
    });

    test('relationship mutations target any current-generation representation but never history', () {
      final target = fixture.message(159542);
      final variantReply = _resolve(
        fixture.evidence(),
        LogicalMutationRequest(
          mutationClass: LogicalMutationClass.reaction,
          targetMessageGuid: target['guid'] as String,
          targetSourceChatRowId: _selfVariantRow,
          targetSourceChatGuid: fixture.chat(_selfVariantRow)['guid'] as String,
        ),
      );
      expect(variantReply.physicalTargetRowIds, [_selfVariantRow]);
      final history = fixture.message(158527);
      final historical = _resolve(
        fixture.evidence(),
        LogicalMutationRequest(
          mutationClass: LogicalMutationClass.reaction,
          targetMessageGuid: history['guid'] as String,
          targetSourceChatRowId: _predecessorRow,
          targetSourceChatGuid: fixture.chat(_predecessorRow)['guid'] as String,
        ),
      );
      expect(historical.reason, 'RELATIONSHIP_TARGET_NOT_IN_CURRENT_EXECUTION_GENERATION');
    });

    test('zero canonical representations blocks as NO_CURRENT_WRITER', () {
      final evidence = fixture.evidence(order: const [_predecessorRow, _selfVariantRow]);
      final authority = _authority(evidence);
      expect(authority.state, LogicalExecutionAuthorityState.blockedNoCurrentWriter);
      expect(authority.blockingPredicate, 'CURRENT_GENERATION_HAS_NO_CANONICAL_ROUTE');
    });

    test('two canonical routes with no era discriminator block as true multi-writer ambiguity', () {
      final twin = _newPhysicalChat(fixture, rowId: 3200, service: 'SMS', messages: const []);
      final evidence = fixture.evidence(
        extraChats: [twin],
        transform: (candidate) => candidate.sourceChatRowId == _canonicalSmsRow
            ? _copy(
                candidate,
                messages: candidate.messages.where((message) => !message.isFromMe).toList(),
                outbounds: const [],
              )
            : candidate,
      );
      final authority = _authority(evidence);
      expect(authority.state, LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity);
      expect(authority.blockingPredicate, 'CURRENT_GENERATION_CANONICAL_ROUTES_WITHOUT_DISCRIMINATOR');
    });

    test('two canonical routes sharing the latest provider timestamp block as a tie', () {
      final at = _naturalReactionAt + 5 * _minute;
      final twin = _newPhysicalChat(
        fixture,
        rowId: 3300,
        service: 'SMS',
        messages: [_msg('twin-outbound', 950001, at, fromMe: true), _msg('twin-reply', 950002, at + _minute)],
      );
      final evidence = fixture.evidence(
        extraChats: [twin],
        extraMessages: {
          _canonicalSmsRow: [_msg('writer-outbound-same-ms', 950003, at, fromMe: true)],
        },
      );
      final authority = _authority(evidence);
      expect(authority.state, LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity);
      expect(authority.blockingPredicate, 'CURRENT_GENERATION_CANONICAL_ROUTE_TIE');
    });

    test('a newer canonical twin cannot borrow corroboration from its sibling row', () {
      final at = _naturalReactionAt + 5 * _minute;
      final twin = _newPhysicalChat(
        fixture,
        rowId: 3400,
        service: 'SMS',
        messages: [_msg('ghost-twin-outbound', 951001, at, fromMe: true)],
      );
      final evidence = fixture.evidence(
        extraChats: [twin],
        extraMessages: {
          _canonicalSmsRow: [_msg('live-chat-reply', 951002, at + _minute)],
        },
      );
      final authority = _authority(evidence);
      expect(authority.isReady, isFalse);
      expect(authority.state, LogicalExecutionAuthorityState.blockedTrueMultiWriterAmbiguity);
      expect(authority.blockingPredicate, 'CURRENT_GENERATION_CANONICAL_ROUTES_WITHOUT_DISCRIMINATOR');

      final answered = fixture.evidence(
        extraChats: [
          {
            ...twin,
            'messages': [
              ...(twin['messages'] as List),
              _msg('twin-own-reply', 951003, at + _minute),
            ],
          },
        ],
      );
      expect(_authority(answered).writerRowId, 3400);
    });

    test('an era boundary tie is excluded from the era whichever message GUID sorts first', () {
      final at = _naturalReactionAt + 5 * _minute;
      final answers = <String>{};
      for (final smsGuid in ['a-sms-boundary', 'z-sms-boundary']) {
        LogicalExecutionAuthority observe({required bool answered}) => _authority(
          fixture.evidence(
            extraMessages: {
              _canonicalSmsRow: [
                _msg(smsGuid, 952001, at, fromMe: true),
                _msg('sms-after-boundary', 952002, at + 1000, fromMe: true),
                if (answered) _msg('sms-boundary-reply', 952003, at + _minute),
              ],
              _predecessorRow: [_msg('m-imessage-boundary', 952004, at, fromMe: true)],
            },
          ),
        );
        final pending = observe(answered: false);
        expect(pending.blockingPredicate, 'CURRENT_GENERATION_EXECUTION_UNCORROBORATED', reason: smsGuid);
        expect(pending.eraStartExclusiveEpoch, at, reason: smsGuid);
        final ready = observe(answered: true);
        expect(ready.isReady, isTrue, reason: smsGuid);
        expect(ready.writerRowId, _canonicalSmsRow);
        answers.add('${pending.revisionMaterial}|${ready.revisionMaterial}');
      }
      expect(answers, hasLength(1));
    });

    test('frontier tie across two generations blocks as ambiguity', () {
      final at = _naturalReactionAt + 5 * _minute;
      final evidence = fixture.evidence(
        extraMessages: {
          _canonicalSmsRow: [_msg('sms-same-ms', 960001, at, fromMe: true)],
          _predecessorRow: [_msg('imessage-same-ms', 960002, at, fromMe: true)],
        },
      );
      expect(_authority(evidence).blockingPredicate, 'EXECUTION_FRONTIER_TIE_ACROSS_GENERATIONS');
    });

    test('writer with forced SMS state contradiction blocks', () {
      final evidence = fixture.evidence(
        transform: (candidate) =>
            candidate.sourceChatRowId == _canonicalSmsRow ? _copy(candidate, forceSms: true) : candidate,
      );
      expect(_authority(evidence).blockingPredicate, 'CURRENT_PROVIDER_FORCE_SMS_STATE_CONTRADICTION');
    });

    test('diagnostics are bounded and carry the required fields', () {
      final authority = _authority(fixture.evidence());
      final diagnostics = authority.diagnostics(
        logicalConversationId: LogicalRuntimeFixture.logicalId,
        certificateRevision: 'certificate',
        authorityRevision: 'authority',
      );
      for (final key in [
        'logical_conversation_id',
        'certificate_revision',
        'authority_revision',
        'current_generation_id',
        'writer_route',
        'writer_evidence_class',
        'alternate_source_roles',
        'blocking_predicate',
        'blocking_evidence',
      ]) {
        expect(diagnostics.containsKey(key), isTrue, reason: key);
      }
      expect(diagnostics['writer_route'], 'SMS canonical route row $_canonicalSmsRow');
      expect(diagnostics['alternate_source_roles'], ['$_predecessorRow:PREDECESSOR', '$_selfVariantRow:SELF_ALIAS_VARIANT']);
      expect(diagnostics.toString().length, lessThan(2000));
    });
  });

  group('failure injection', () {
    LogicalRouteEvidence inject(LogicalRouteEvidence Function(LogicalRouteEvidence base) mutate) =>
        mutate(fixture.evidence());

    LogicalRouteEvidence rebuild(
      LogicalRouteEvidence base, {
      bool? privateApi,
      String? accountAfter,
      bool? scopeComplete,
    }) => LogicalRouteEvidence(
      logicalId: base.logicalId,
      certificateId: base.certificateId,
      certifiedSourceChatGuids: base.certifiedSourceChatGuids,
      backendComputerId: base.backendComputerId,
      detectedIMessage: base.detectedIMessage,
      privateApiConnected: privateApi ?? base.privateApiConnected,
      helperConnected: base.helperConnected,
      accountSnapshotBeforeSha256: base.accountSnapshotBeforeSha256,
      accountSnapshotAfterSha256: accountAfter ?? base.accountSnapshotAfterSha256,
      activeSelfAlias: base.activeSelfAlias,
      vettedSelfAliases: base.vettedSelfAliases,
      executionGenerationCertificate: base.executionGenerationCertificate,
      candidateScopeSnapshotComplete: scopeComplete ?? base.candidateScopeSnapshotComplete,
      unadmittedPotentialSourceChatGuids: base.unadmittedPotentialSourceChatGuids,
      candidates: base.candidates,
    );

    test('provider and snapshot faults fail closed with their own predicate, never a writer change', () {
      final cases = <String, LogicalRouteEvidence>{
        'CURRENT_TRANSPORT_CONTEXT_UNPROVEN': inject((base) => rebuild(base, privateApi: false)),
        'CURRENT_ACCOUNT_IDENTITY_UNSTABLE': inject((base) => rebuild(base, accountAfter: 'f' * 64)),
        'POTENTIAL_EXECUTION_CANDIDATE_SCOPE_UNSTABLE': inject((base) => rebuild(base, scopeComplete: false)),
        'CURRENT_MESSAGE_PROVENANCE_INCOMPLETE': inject(
          (base) => _withCandidates(base, [
            for (final candidate in base.candidates)
              candidate.sourceChatRowId == _selfVariantRow
                  ? LogicalRouteCandidateEvidence(
                      sourceChatRowId: candidate.sourceChatRowId,
                      sourceChatGuid: candidate.sourceChatGuid,
                      sourceService: candidate.sourceService,
                      sourceAccount: candidate.sourceAccount,
                      chatIdentifier: candidate.chatIdentifier,
                      style: candidate.style,
                      lastAddressedHandle: candidate.lastAddressedHandle,
                      participants: candidate.participants,
                      chatSnapshotComplete: candidate.chatSnapshotComplete,
                      messageSnapshotComplete: false,
                      lastKnownHybridState: candidate.lastKnownHybridState,
                      shouldForceToSms: candidate.shouldForceToSms,
                      lastSeenMessageGuid: candidate.lastSeenMessageGuid,
                      groupPhotoGuid: candidate.groupPhotoGuid,
                      groupIdentifier: candidate.groupIdentifier,
                      messages: candidate.messages,
                      successfulOutbounds: candidate.successfulOutbounds,
                      sourceAccountFact: candidate.sourceAccountFact,
                    )
                  : candidate,
          ]),
        ),
        'SUCCESSFUL_OUTBOUND_PROVENANCE_AMBIGUOUS': inject(
          (base) => _withCandidates(base, [
            for (final candidate in base.candidates)
              candidate.sourceChatRowId == _selfVariantRow
                  ? _copy(
                      candidate,
                      outbounds: [
                        ...candidate.successfulOutbounds,
                        base.candidates
                            .singleWhere((other) => other.sourceChatRowId == _canonicalSmsRow)
                            .successfulOutbounds
                            .last,
                      ],
                    )
                  : candidate,
          ]),
        ),
      };
      for (final entry in cases.entries) {
        final decision = _resolve(entry.value);
        expect(decision.isQualified, isFalse, reason: entry.key);
        expect(decision.reason, entry.key);
      }
    });

    test('missing Tier-5 read pointers and group metadata are unavailable, not blocking', () {
      final evidence = _withCandidates(fixture.evidence(), [
        for (final candidate in fixture.evidence().candidates)
          LogicalRouteCandidateEvidence(
            sourceChatRowId: candidate.sourceChatRowId,
            sourceChatGuid: candidate.sourceChatGuid,
            sourceService: candidate.sourceService,
            sourceAccount: candidate.sourceAccount,
            chatIdentifier: candidate.chatIdentifier,
            style: candidate.style,
            lastAddressedHandle: candidate.lastAddressedHandle,
            participants: candidate.participants,
            chatSnapshotComplete: true,
            messageSnapshotComplete: true,
            lastKnownHybridState: null,
            shouldForceToSms: candidate.shouldForceToSms,
            lastSeenMessageGuid: null,
            groupPhotoGuid: null,
            groupIdentifier: null,
            messages: candidate.messages,
            successfulOutbounds: candidate.successfulOutbounds,
            sourceAccountFact: candidate.sourceAccountFact,
          ),
      ]);
      expect(_resolve(evidence).physicalTargetRowIds, [_canonicalSmsRow]);
    });

    test('convergence cost stays bounded on the full runtime history', () {
      _resolve(fixture.evidence());
      final observations = [for (var index = 0; index < 10; index++) fixture.evidence()];
      final stopwatch = Stopwatch()..start();
      for (final evidence in observations) {
        _resolve(evidence);
        LogicalConversationOutboundRoutePolicy.executionAuthority(evidence);
        _resolve(evidence);
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds / observations.length, lessThan(250));
    });
  });

  group('property and permutation tests', () {
    // Synthetic universe with arbitrary ROWIDs: two services, one SMS self
    // variant, and a random history. No production coordinate is reused.
    const iMessageRow = 71;
    const smsRow = 72;
    const smsVariantRow = 73;

    List<Map<String, dynamic>> synthChats(Random random, {required bool withOutbounds}) {
      final template = {for (final row in [_predecessorRow, _canonicalSmsRow, _selfVariantRow]) row: fixture.chat(row)};
      var clock = 1700000000000;
      final messages = <int, List<Map<String, dynamic>>>{iMessageRow: [], smsRow: [], smsVariantRow: []};
      var rowId = 1;
      for (var index = 0; index < 40; index++) {
        clock += 1000 + random.nextInt(600000);
        final row = [iMessageRow, smsRow, smsVariantRow][random.nextInt(3)];
        final fromMe = withOutbounds && random.nextInt(3) == 0;
        messages[row]!.add(_msg('m$rowId', rowId, clock, fromMe: fromMe, error: fromMe && random.nextInt(5) == 0 ? 4 : 0));
        rowId += 1;
      }
      Map<String, dynamic> chat(int row, int templateRow) => <String, dynamic>{
        ...template[templateRow]!,
        'rowId': row,
        'guid': '${template[templateRow]!['service']};+;chat-synthetic-$row',
        'messages': messages[row],
      };
      return [chat(iMessageRow, _predecessorRow), chat(smsRow, _canonicalSmsRow), chat(smsVariantRow, _selfVariantRow)];
    }

    LogicalRouteEvidence synthEvidence(List<Map<String, dynamic>> chats, {Map<int, List<Map<String, dynamic>>>? extra}) {
      return fixture.withChats(chats).evidence(extraMessages: extra ?? const {});
    }

    List<Map<String, dynamic>> readOnlyEvents(Random random, List<Map<String, dynamic>> chats, int after) {
      final all = chats.expand((chat) => (chat['messages'] as List).cast<Map<String, dynamic>>()).toList();
      return [
        for (var index = 0; index < 1 + random.nextInt(6); index++)
          () {
            final at = after + 1 + random.nextInt(4 * 60 * _minute);
            final kind = random.nextInt(3);
            final target = all.isEmpty ? null : all[random.nextInt(all.length)]['guid'] as String;
            return _msg(
              'read-$index-${random.nextInt(1 << 30)}',
              800000 + index,
              at,
              associated: kind == 1 && target != null ? 'p:0/$target' : null,
              thread: kind == 2 && target != null ? target : null,
            );
          }(),
      ];
    }

    test('same evidence always yields the same writer, across permutations', () {
      final random = Random(1);
      for (var iteration = 0; iteration < 60; iteration++) {
        final chats = synthChats(random, withOutbounds: true);
        final base = synthEvidence(chats);
        final expected = _resolve(base);
        final shuffled = _withCandidates(base, [
          for (final candidate in base.candidates.toList()..shuffle(random))
            _copy(candidate, messages: candidate.messages.toList()..shuffle(random)),
        ]);
        final actual = _resolve(shuffled);
        expect(actual.reason, expected.reason);
        expect(actual.physicalTargetRowIds, expected.physicalTargetRowIds);
      }
    });

    test('read-side activity can neither remove nor re-select a writer', () {
      final random = Random(2);
      var readyCases = 0;
      var blockedCases = 0;
      for (var iteration = 0; iteration < 300; iteration++) {
        final chats = synthChats(random, withOutbounds: true);
        final base = synthEvidence(chats);
        final before = _authority(base);
        final last = chats
            .expand((chat) => (chat['messages'] as List).cast<Map<String, dynamic>>())
            .fold<int>(0, (latest, message) => max(latest, message['dateCreated'] as int));
        final row = [iMessageRow, smsRow, smsVariantRow][random.nextInt(3)];
        final after = _authority(synthEvidence(chats, extra: {row: readOnlyEvents(random, chats, last)}));
        if (before.isReady) {
          readyCases += 1;
          expect(after.isReady, isTrue, reason: 'READY -> ${after.blockingPredicate}');
          expect(after.writerRowId, before.writerRowId);
          expect(after.revisionMaterial, before.revisionMaterial);
        } else {
          blockedCases += 1;
          expect(after.currentGenerationId, before.currentGenerationId);
          if (after.isReady) {
            expect(before.currentGenerationRowIds.contains(after.writerRowId), isTrue);
          }
        }
      }
      expect(readyCases, greaterThan(20));
      expect(blockedCases, greaterThan(5));
    });

    test('read-side corroboration arms exactly the frontier writer and never another row', () {
      final random = Random(7);
      var pendingCases = 0;
      for (var iteration = 0; iteration < 120; iteration++) {
        final chats = synthChats(random, withOutbounds: true);
        final last = chats
            .expand((chat) => (chat['messages'] as List).cast<Map<String, dynamic>>())
            .fold<int>(0, (latest, message) => max(latest, message['dateCreated'] as int));
        final frontier = {smsRow: [_msg('frontier-outbound', 710001, last + 1000, fromMe: true)]};
        final pending = _authority(synthEvidence(chats, extra: frontier));
        if (pending.blockingPredicate != 'CURRENT_GENERATION_EXECUTION_UNCORROBORATED') continue;
        pendingCases += 1;

        final foreignReply = _authority(
          synthEvidence(
            chats,
            extra: {
              ...frontier,
              iMessageRow: [_msg('foreign-reply', 710002, last + 60000)],
            },
          ),
        );
        expect(foreignReply.isReady, isFalse);
        expect(foreignReply.currentGenerationId, pending.currentGenerationId);

        final variantReply = _authority(
          synthEvidence(
            chats,
            extra: {
              ...frontier,
              smsVariantRow: [_msg('variant-reply', 710003, last + 60000)],
            },
          ),
        );
        expect(variantReply.isReady, isTrue, reason: variantReply.blockingPredicate);
        expect(variantReply.writerRowId, smsRow);
      }
      expect(pendingCases, greaterThan(20));
    });

    test('read-side activity without any outbound cannot create a writer', () {
      final random = Random(3);
      for (var iteration = 0; iteration < 100; iteration++) {
        final chats = synthChats(random, withOutbounds: false);
        final extra = {smsRow: readOnlyEvents(random, chats, 1700000000000)};
        final authority = _authority(synthEvidence(chats, extra: extra));
        expect(authority.isReady, isFalse);
        expect(authority.state, LogicalExecutionAuthorityState.blockedNoCurrentWriter);
      }
    });

    test('a present contradiction always blocks regardless of history', () {
      final random = Random(4);
      for (var iteration = 0; iteration < 40; iteration++) {
        final base = synthEvidence(synthChats(random, withOutbounds: true));
        final row = base.candidates[random.nextInt(base.candidates.length)].sourceChatRowId;
        final contradicted = _withCandidates(base, [
          for (final candidate in base.candidates)
            candidate.sourceChatRowId == row
                ? _copy(
                    candidate,
                    sourceAccountFact: const LogicalProviderFactEvidence(
                      state: LogicalProviderFactState.presentAndContradicts,
                    ),
                  )
                : candidate,
        ]);
        expect(_resolve(contradicted).isQualified, isFalse);
      }
    });

    test('a singular corroborated writer is eventually READY', () {
      final random = Random(5);
      for (var iteration = 0; iteration < 60; iteration++) {
        final chats = synthChats(random, withOutbounds: true);
        final last = chats
            .expand((chat) => (chat['messages'] as List).cast<Map<String, dynamic>>())
            .fold<int>(0, (latest, message) => max(latest, message['dateCreated'] as int));
        final authority = _authority(
          synthEvidence(
            chats,
            extra: {
              smsRow: [_msg('settling-outbound', 700001, last + 1000, fromMe: true)],
              smsVariantRow: [_msg('settling-reply', 700002, last + 60000)],
            },
          ),
        );
        expect(authority.isReady, isTrue, reason: authority.blockingPredicate);
        expect(authority.writerRowId, smsRow);
      }
    });

    test('ROWID relabeling permutes the answer and never changes it', () {
      final random = Random(6);
      for (var iteration = 0; iteration < 40; iteration++) {
        final chats = synthChats(random, withOutbounds: true);
        final relabel = {iMessageRow: 9001 + iteration, smsRow: 5003 + iteration, smsVariantRow: 7002 + iteration};
        final relabeled = [
          for (final chat in chats)
            <String, dynamic>{
              ...chat,
              'rowId': relabel[chat['rowId']],
              'guid': '${chat['service']};+;chat-relabeled-${relabel[chat['rowId']]}',
            },
        ];
        final original = _authority(synthEvidence(chats));
        final moved = _authority(synthEvidence(relabeled));
        expect(moved.state, original.state);
        expect(moved.blockingPredicate, original.blockingPredicate);
        expect(moved.writerRowId, original.writerRowId == null ? null : relabel[original.writerRowId]);
      }
    });
  });
}
