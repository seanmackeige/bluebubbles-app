import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_candidate_reconciliation_context.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_route.dart';
import 'package:flutter_test/flutter_test.dart';

const _revisionA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _revisionB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _account = 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

LogicalAddressEvidence _address(String value) => LogicalAddressEvidence(address: value, country: 'US');

LogicalCandidateReconciliationContext _context({
  required String logicalSeed,
  String revision = _revisionA,
  String service = 'SMS',
  List<String> external = const <String>['+14155550100', 'person@example.test'],
  List<String> aliases = const <String>['+14155550999'],
}) {
  final context = LogicalCandidateReconciliationContext.derive(
    targetLogicalId: LogicalConversationId.certified(logicalSeed),
    certificateRevision: revision,
    certifiedSources: <LogicalCandidateContextSource>[
      LogicalCandidateContextSource(service: service, participants: external.map(_address).toList(growable: false)),
      LogicalCandidateContextSource(
        service: service,
        participants: <LogicalAddressEvidence>[...external.map(_address), ...aliases.map(_address)],
      ),
    ],
    vettedAliases: aliases.map(_address),
    providerAccountFingerprint: _account,
  );
  expect(context, isNotNull);
  return context!;
}

void main() {
  group('generic logical candidate context', () {
    test('matches an exact external set across a vetted self-alias variant', () {
      final context = _context(logicalSeed: 'conversation-a');

      expect(
        context.matchesCandidate(
          service: 'SMS',
          participants: <LogicalAddressEvidence>[_address('PERSON@example.test'), _address('+1 (415) 555-0100')],
        ),
        isTrue,
      );
      expect(
        context.matchesCandidate(
          service: 'SMS',
          participants: <LogicalAddressEvidence>[
            _address('+14155550999'),
            _address('+14155550100'),
            _address('person@example.test'),
          ],
        ),
        isTrue,
      );
    });

    test('rejects service, participant, duplicate and invalid-address drift', () {
      final context = _context(logicalSeed: 'conversation-a');

      expect(
        context.matchesCandidate(
          service: 'iMessage',
          participants: <LogicalAddressEvidence>[_address('+14155550100'), _address('person@example.test')],
        ),
        isFalse,
      );
      expect(
        context.matchesCandidate(
          service: 'SMS',
          participants: <LogicalAddressEvidence>[_address('+14155550101'), _address('person@example.test')],
        ),
        isFalse,
      );
      expect(
        context.matchesCandidate(
          service: 'SMS',
          participants: <LogicalAddressEvidence>[
            _address('+14155550100'),
            _address('+1 (415) 555-0100'),
            _address('person@example.test'),
          ],
        ),
        isFalse,
      );
      expect(
        context.matchesCandidate(
          service: 'SMS',
          participants: <LogicalAddressEvidence>[_address('not-routable'), _address('person@example.test')],
        ),
        isFalse,
      );
    });

    test('fails closed when certified sources disagree after alias removal', () {
      final context = LogicalCandidateReconciliationContext.derive(
        targetLogicalId: LogicalConversationId.certified('conversation-a'),
        certificateRevision: _revisionA,
        certifiedSources: <LogicalCandidateContextSource>[
          LogicalCandidateContextSource(
            service: 'SMS',
            participants: <LogicalAddressEvidence>[_address('+14155550100')],
          ),
          LogicalCandidateContextSource(
            service: 'SMS',
            participants: <LogicalAddressEvidence>[_address('+14155550101')],
          ),
        ],
        vettedAliases: const <LogicalAddressEvidence>[],
        providerAccountFingerprint: _account,
      );

      expect(context, isNull);
    });

    test('returns a unique target without granting certificate membership', () {
      final target = LogicalConversationId.certified('conversation-a');
      final ledger = LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        _context(logicalSeed: 'conversation-a'),
        _context(logicalSeed: 'conversation-b', revision: _revisionB, external: const <String>['+14155550111']),
      ]);

      final match = ledger.matchCandidate(
        service: 'SMS',
        participants: <LogicalAddressEvidence>[_address('+14155550100'), _address('person@example.test')],
      );

      expect(match.kind, LogicalCandidateContextMatchKind.unique);
      expect(match.uniqueTarget, target);
      expect(match.targets, <LogicalConversationId>[target]);
    });

    test('a candidate for the second certificate resolves only to that logical identity', () {
      final first = _context(logicalSeed: 'conversation-a');
      final second = _context(
        logicalSeed: 'conversation-b',
        revision: _revisionB,
        external: const <String>['+14155550111'],
      );
      final ledger = LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        first,
        second,
      ]);

      final match = ledger.matchCandidate(
        service: 'SMS',
        participants: <LogicalAddressEvidence>[_address('+1 (415) 555-0111')],
      );

      expect(match.kind, LogicalCandidateContextMatchKind.unique);
      expect(match.uniqueTarget, second.targetLogicalId);
      expect(match.targets, isNot(contains(first.targetLogicalId)));
    });

    test('cross-conversation exact-set collision is explicitly ambiguous', () {
      final first = _context(logicalSeed: 'conversation-a');
      final second = _context(logicalSeed: 'conversation-b', revision: _revisionB);
      final ledger = LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        first,
        second,
      ]);

      final match = ledger.matchCandidate(
        service: 'SMS',
        participants: <LogicalAddressEvidence>[_address('+14155550100'), _address('person@example.test')],
      );

      expect(match.kind, LogicalCandidateContextMatchKind.ambiguous);
      expect(match.uniqueTarget, isNull);
      expect(match.targets.toSet(), <LogicalConversationId>{first.targetLogicalId, second.targetLogicalId});
    });

    test('ledger is deterministic, restart-safe and contains no raw identity', () {
      final first = _context(logicalSeed: 'conversation-a');
      final second = _context(
        logicalSeed: 'conversation-b',
        revision: _revisionB,
        external: const <String>['+14155550111'],
      );
      final forward = LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        first,
        second,
      ]);
      final reverse = LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        second,
        first,
      ]);

      expect(reverse.encode(), forward.encode());
      expect(LogicalCandidateReconciliationContextLedger.decode(forward.encode()).encode(), forward.encode());
      expect(forward.encode(), isNot(contains('+14155550100')));
      expect(forward.encode(), isNot(contains('person@example.test')));
      expect(forward.encode(), isNot(contains('+14155550999')));
    });

    test('restart pruning cannot retarget a context or make a stale revision current', () {
      final first = _context(logicalSeed: 'conversation-a');
      final second = _context(
        logicalSeed: 'conversation-b',
        revision: _revisionB,
        external: const <String>['+14155550111'],
      );
      final restored = LogicalCandidateReconciliationContextLedger.decode(
        LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[first, second]).encode(),
      ).retainTargets(<LogicalConversationId>[second.targetLogicalId]);

      expect(restored.contexts, hasLength(1));
      expect(restored.contextFor(first.targetLogicalId), isNull);
      expect(restored.contextFor(second.targetLogicalId)?.stableFingerprint, second.stableFingerprint);
      expect(restored.isCurrent(restored.contexts.single, _revisionB), isTrue);
      expect(restored.isCurrent(restored.contexts.single, _revisionA), isFalse);
      final match = restored.matchCandidate(
        service: 'SMS',
        participants: <LogicalAddressEvidence>[_address('+14155550111')],
      );
      expect(match.uniqueTarget, second.targetLogicalId);
    });

    test('tampered ledger revision and record fingerprint fail closed', () {
      final ledger = LogicalCandidateReconciliationContextLedger(<LogicalCandidateReconciliationContext>[
        _context(logicalSeed: 'conversation-a'),
      ]);
      final revisionTamper = (jsonDecode(ledger.encode()) as Map).cast<String, dynamic>()..['revision'] = _revisionB;
      expect(
        () => LogicalCandidateReconciliationContextLedger.decode(jsonEncode(revisionTamper)),
        throwsFormatException,
      );

      final recordTamper = (jsonDecode(ledger.encode()) as Map).cast<String, dynamic>();
      final record = ((recordTamper['contexts'] as Map).values.single as Map).cast<String, dynamic>();
      record['stableFingerprint'] = _revisionB;
      expect(() => LogicalCandidateReconciliationContextLedger.decode(jsonEncode(recordTamper)), throwsFormatException);
    });
  });
}
