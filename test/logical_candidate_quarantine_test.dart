import 'dart:convert';

import 'package:bluebubbles/services/ui/chat/logical_candidate_quarantine.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('logical candidate quarantine state machine', () {
    test('requires reconciliation and an independent certificate before projection', () {
      final fixture = _fixture('happy');
      final ledger = LogicalCandidateQuarantineLedger.empty();

      final nominated = ledger.nominate(fixture.nomination, nowEpochMs: 1000, quarantineDurationMs: 500);
      expect(nominated.disposition, LogicalCandidateTransitionDisposition.applied);
      expect(nominated.record!.phase, LogicalCandidateQuarantinePhase.nominated);
      expect(nominated.record!.canJoinLogicalProjection, isFalse);
      expect(nominated.record!.mayBeTemporarilySuppressedAt(1000), isTrue);

      final reconciling = ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 1010);
      expect(reconciling.disposition, LogicalCandidateTransitionDisposition.applied);
      expect(reconciling.record!.phase, LogicalCandidateQuarantinePhase.reconciling);
      expect(reconciling.record!.canJoinLogicalProjection, isFalse);

      final certified = ledger.applyEvidence(fixture.certificate(), nowEpochMs: 1020);
      expect(certified.disposition, LogicalCandidateTransitionDisposition.applied);
      expect(certified.record!.phase, LogicalCandidateQuarantinePhase.certified);
      expect(certified.record!.canJoinLogicalProjection, isTrue);
      expect(certified.record!.certificateFingerprint, fixture.certificateFingerprint);
    });

    test('exact-set equality alone cannot certify or auto-enroll a candidate', () {
      final fixture = _fixture('exact-set-only');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 50);

      final directCertificate = ledger.applyEvidence(fixture.certificate(sequence: 1), nowEpochMs: 101);

      expect(directCertificate.disposition, LogicalCandidateTransitionDisposition.rejectedFailClosed);
      expect(directCertificate.record!.phase, LogicalCandidateQuarantinePhase.rejected);
      expect(directCertificate.record!.rejectionReason, LogicalCandidateRejectionReason.evidenceOutOfOrder);
      expect(directCertificate.record!.canJoinLogicalProjection, isFalse);
      expect(directCertificate.record!.mustRemainPhysicallyVisibleAt(101), isTrue);
    });

    test('certificate issuer must be independent from nomination and reconciliation authorities', () {
      for (final authority in <String>[_fp('authority-nominator'), _fp('authority-reconciler')]) {
        final fixture = _fixture(
          'non-independent-$authority',
          nominatorFingerprint: _fp('authority-nominator'),
          reconciliationAuthorityFingerprint: _fp('authority-reconciler'),
        );
        final ledger = LogicalCandidateQuarantineLedger.empty();
        ledger.nominate(fixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
        ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 1);

        final result = ledger.applyEvidence(fixture.certificate(authorityFingerprint: authority), nowEpochMs: 2);

        expect(result.disposition, LogicalCandidateTransitionDisposition.rejectedFailClosed);
        expect(result.record!.rejectionReason, LogicalCandidateRejectionReason.nonIndependentCertificate);
        expect(result.record!.mustRemainPhysicallyVisibleAt(2), isTrue);
      }
    });

    test('explicit negative evidence rejects visibly from either active phase', () {
      for (final reconcileFirst in <bool>[false, true]) {
        final fixture = _fixture('negative-$reconcileFirst');
        final ledger = LogicalCandidateQuarantineLedger.empty();
        ledger.nominate(fixture.nomination, nowEpochMs: 10, quarantineDurationMs: 100);
        if (reconcileFirst) ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 11);

        final result = ledger.applyEvidence(fixture.rejection(sequence: reconcileFirst ? 2 : 1), nowEpochMs: 12);

        expect(result.record!.phase, LogicalCandidateQuarantinePhase.rejected);
        expect(result.record!.rejectionReason, LogicalCandidateRejectionReason.independentEvidenceRejected);
        expect(result.record!.mustRemainPhysicallyVisibleAt(12), isTrue);
      }
    });
  });

  group('bounded visibility quarantine', () {
    test('deadline materializes EXPIRED_VISIBLE and restart cannot extend it', () {
      final fixture = _fixture('deadline');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 1000, quarantineDurationMs: 50);
      ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 1010);

      final before = ledger.recordFor(fixture.nomination.candidate, nowEpochMs: 1049)!;
      expect(before.phase, LogicalCandidateQuarantinePhase.reconciling);
      expect(before.mayBeTemporarilySuppressedAt(1049), isTrue);
      final persisted = ledger.toJson(nowEpochMs: 1049);

      final restarted = LogicalCandidateQuarantineLedger.fromJson(persisted, nowEpochMs: 1050);
      final expired = restarted.recordFor(fixture.nomination.candidate, nowEpochMs: 1050)!;
      expect(expired.phase, LogicalCandidateQuarantinePhase.expiredVisible);
      expect(expired.rejectionReason, LogicalCandidateRejectionReason.quarantineExpired);
      expect(expired.mustRemainPhysicallyVisibleAt(1050), isTrue);
      expect(expired.canJoinLogicalProjection, isFalse);
      expect(expired.lastTransitionAtEpochMs, 1050);

      final muchLater = LogicalCandidateQuarantineLedger.fromJson(persisted, nowEpochMs: 9000);
      expect(jsonEncode(muchLater.toJson(nowEpochMs: 9000)), jsonEncode(restarted.toJson(nowEpochMs: 1050)));

      final lateEvidence = LogicalCandidateQuarantineLedger.fromJson(
        persisted,
        nowEpochMs: 1050,
      ).applyEvidence(fixture.certificate(), nowEpochMs: 1050);
      expect(lateEvidence.disposition, LogicalCandidateTransitionDisposition.terminalIgnored);
      expect(lateEvidence.record!.phase, LogicalCandidateQuarantinePhase.expiredVisible);
    });

    test('duplicate nominations never refresh the original visibility deadline', () {
      final fixture = _fixture('duplicate-deadline');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 50);

      for (var now = 101; now < 150; now += 1) {
        final duplicate = ledger.nominate(
          fixture.nomination,
          nowEpochMs: now,
          quarantineDurationMs: LogicalCandidateQuarantineLedger.maxQuarantineDurationMs,
        );
        expect(duplicate.disposition, LogicalCandidateTransitionDisposition.duplicateIgnored);
        expect(duplicate.record!.quarantineDeadlineEpochMs, 150);
      }

      final expired = ledger.recordFor(fixture.nomination.candidate, nowEpochMs: 150)!;
      expect(expired.phase, LogicalCandidateQuarantinePhase.expiredVisible);
      expect(expired.mustRemainPhysicallyVisibleAt(150), isTrue);
    });

    test('clock rollback fails active quarantine open instead of extending hiding', () {
      final fixture = _fixture('clock-regression');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 50);

      final regressed = ledger.recordFor(fixture.nomination.candidate, nowEpochMs: 99)!;

      expect(regressed.phase, LogicalCandidateQuarantinePhase.rejected);
      expect(regressed.rejectionReason, LogicalCandidateRejectionReason.clockRegression);
      expect(regressed.mustRemainPhysicallyVisibleAt(99), isTrue);
    });

    test('every admitted duration is bounded and its exact deadline is visible', () {
      for (var duration = 1; duration <= 128; duration += 1) {
        final fixture = _fixture('duration-$duration');
        final ledger = LogicalCandidateQuarantineLedger.empty();
        final start = duration * 1000;
        ledger.nominate(fixture.nomination, nowEpochMs: start, quarantineDurationMs: duration);

        expect(
          ledger.recordFor(fixture.nomination.candidate, nowEpochMs: start + duration - 1)!.canJoinLogicalProjection,
          isFalse,
        );
        final atDeadline = ledger.recordFor(fixture.nomination.candidate, nowEpochMs: start + duration)!;
        expect(atDeadline.phase, LogicalCandidateQuarantinePhase.expiredVisible);
        expect(atDeadline.mustRemainPhysicallyVisibleAt(start + duration), isTrue);
      }
    });

    test('projection suppression requires a live target and holds certification until activation', () {
      final fixture = _fixture('projection-policy');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 50);
      final nominated = ledger.recordFor(fixture.nomination.candidate, nowEpochMs: 100);

      expect(
        shouldTemporarilySuppressLogicalCandidate(
          record: nominated,
          nowEpochMs: 100,
          targetProjectionAvailable: true,
          admittedToActiveCertificate: false,
        ),
        isTrue,
      );
      expect(
        shouldTemporarilySuppressLogicalCandidate(
          record: nominated,
          nowEpochMs: 100,
          targetProjectionAvailable: false,
          admittedToActiveCertificate: false,
        ),
        isFalse,
      );

      ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 101);
      ledger.applyEvidence(fixture.certificate(), nowEpochMs: 102);
      final certified = ledger.recordFor(fixture.nomination.candidate, nowEpochMs: 102);
      expect(certified!.canJoinLogicalProjection, isTrue);
      expect(
        shouldTemporarilySuppressLogicalCandidate(
          record: certified,
          nowEpochMs: 102,
          targetProjectionAvailable: true,
          admittedToActiveCertificate: false,
        ),
        isTrue,
      );
      expect(
        shouldTemporarilySuppressLogicalCandidate(
          record: certified,
          nowEpochMs: 102,
          targetProjectionAvailable: true,
          admittedToActiveCertificate: true,
        ),
        isFalse,
      );
    });

    test('first-frame potential is hidden only until a durable record decides visibility', () {
      expect(
        shouldSuppressFirstFramePotentialCandidate(
          hasCandidateRecord: false,
          provenPotentialPredicate: true,
          targetProjectionAvailable: true,
        ),
        isTrue,
      );
      for (final state in <({bool record, bool potential, bool target})>[
        (record: true, potential: true, target: true),
        (record: false, potential: false, target: true),
        (record: false, potential: true, target: false),
      ]) {
        expect(
          shouldSuppressFirstFramePotentialCandidate(
            hasCandidateRecord: state.record,
            provenPotentialPredicate: state.potential,
            targetProjectionAvailable: state.target,
          ),
          isFalse,
        );
      }
    });

    test('shared presentation admission is phase-aware and certificate-gated', () {
      expect(
        logicalCandidatePresentationAdmission(phase: null, admittedToActiveCertificate: false),
        LogicalCandidatePresentationAdmission.ordinary,
      );
      for (final phase in <LogicalCandidateQuarantinePhase>[
        LogicalCandidateQuarantinePhase.nominated,
        LogicalCandidateQuarantinePhase.reconciling,
        LogicalCandidateQuarantinePhase.certified,
      ]) {
        expect(
          logicalCandidatePresentationAdmission(phase: phase, admittedToActiveCertificate: false),
          LogicalCandidatePresentationAdmission.suppressPhysical,
        );
      }
      for (final phase in <LogicalCandidateQuarantinePhase>[
        LogicalCandidateQuarantinePhase.rejected,
        LogicalCandidateQuarantinePhase.expiredVisible,
      ]) {
        expect(
          logicalCandidatePresentationAdmission(phase: phase, admittedToActiveCertificate: false),
          LogicalCandidatePresentationAdmission.ordinaryReadOnly,
        );
      }
      expect(
        logicalCandidatePresentationAdmission(
          phase: LogicalCandidateQuarantinePhase.certified,
          admittedToActiveCertificate: true,
        ),
        LogicalCandidatePresentationAdmission.canonicalLogical,
      );
    });

    test('candidate unread contribution never bounces into a duplicate count', () {
      int aggregate({required bool certified, required bool suppressed, required bool logicalUnread}) =>
          (shouldCountPhysicalUnreadAsOrdinary(certifiedSource: certified, temporarilySuppressed: suppressed) ? 1 : 0) +
          (logicalUnread ? 1 : 0);

      // The first frame is already quarantined by the proven predicate.
      final firstFrameSuppressed = shouldSuppressFirstFramePotentialCandidate(
        hasCandidateRecord: false,
        provenPotentialPredicate: true,
        targetProjectionAvailable: true,
      );
      expect(aggregate(certified: false, suppressed: firstFrameSuppressed, logicalUnread: false), 0);

      final rejectedFixture = _fixture('unread-rejected');
      final rejectedLedger = LogicalCandidateQuarantineLedger.empty();
      rejectedLedger.nominate(rejectedFixture.nomination, nowEpochMs: 100, quarantineDurationMs: 50);
      final nominated = rejectedLedger.recordFor(rejectedFixture.nomination.candidate, nowEpochMs: 100)!;
      final nominatedSuppressed = shouldTemporarilySuppressLogicalCandidate(
        record: nominated,
        nowEpochMs: 100,
        targetProjectionAvailable: true,
        admittedToActiveCertificate: false,
      );
      expect(aggregate(certified: false, suppressed: nominatedSuppressed, logicalUnread: false), 0);

      rejectedLedger.applyEvidence(rejectedFixture.rejection(sequence: 1), nowEpochMs: 101);
      final rejected = rejectedLedger.recordFor(rejectedFixture.nomination.candidate, nowEpochMs: 101)!;
      final rejectedSuppressed = shouldTemporarilySuppressLogicalCandidate(
        record: rejected,
        nowEpochMs: 101,
        targetProjectionAvailable: true,
        admittedToActiveCertificate: false,
      );
      expect(aggregate(certified: false, suppressed: rejectedSuppressed, logicalUnread: false), 1);

      final certifiedFixture = _fixture('unread-certified');
      final certifiedLedger = LogicalCandidateQuarantineLedger.empty();
      certifiedLedger.nominate(certifiedFixture.nomination, nowEpochMs: 200, quarantineDurationMs: 50);
      certifiedLedger.applyEvidence(certifiedFixture.reconciliation(), nowEpochMs: 201);
      certifiedLedger.applyEvidence(certifiedFixture.certificate(), nowEpochMs: 202);
      final certified = certifiedLedger.recordFor(certifiedFixture.nomination.candidate, nowEpochMs: 202)!;
      expect(
        shouldTemporarilySuppressLogicalCandidate(
          record: certified,
          nowEpochMs: 202,
          targetProjectionAvailable: true,
          admittedToActiveCertificate: false,
        ),
        isTrue,
      );
      final certifiedSuppressed = shouldTemporarilySuppressLogicalCandidate(
        record: certified,
        nowEpochMs: 202,
        targetProjectionAvailable: true,
        admittedToActiveCertificate: true,
      );
      expect(certifiedSuppressed, isFalse);
      // The physical source contributes zero while the logical aggregate
      // contributes exactly once after certificate activation.
      expect(aggregate(certified: true, suppressed: certifiedSuppressed, logicalUnread: true), 1);
    });

    test('candidate target matching uses typed application identity rather than raw certificate text', () {
      const rawCertificateId = 'LGC_V2_banked-target';
      final expected = LogicalConversationId.certified(rawCertificateId);
      final nomination = LogicalCandidateNomination(
        candidate: PhysicalConversationRef.fromStablePhysicalGuid('typed-target-candidate'),
        targetLogicalId: expected,
        exactParticipantSetFingerprint: _fp('typed-target-participants'),
        serviceFingerprint: _fp('typed-target-service'),
        accountFingerprint: _fp('typed-target-account'),
        nominationEvidenceFingerprint: _fp('typed-target-evidence'),
        nominatorFingerprint: _fp('typed-target-nominator'),
      );
      final ledger = LogicalCandidateQuarantineLedger.empty();
      final record = ledger.nominate(nomination, nowEpochMs: 1, quarantineDurationMs: 50).record!;

      expect(logicalCandidateTargets(record, expected), isTrue);
      expect(logicalCandidateTargets(record, LogicalConversationId.certified(expected.value)), isFalse);
      expect(record.targetLogicalId.value, isNot(rawCertificateId));
    });

    test('invalid or unbounded quarantine durations are rejected', () {
      final fixture = _fixture('bad-duration');
      for (final duration in <int>[0, -1, LogicalCandidateQuarantineLedger.maxQuarantineDurationMs + 1]) {
        expect(
          () => LogicalCandidateQuarantineLedger.empty().nominate(
            fixture.nomination,
            nowEpochMs: 0,
            quarantineDurationMs: duration,
          ),
          throwsArgumentError,
        );
      }
    });
  });

  group('duplicate and out-of-order evidence', () {
    test('exact duplicate is idempotent while conflicting same-sequence evidence rejects visibly', () {
      final fixture = _fixture('duplicate-evidence');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      final evidence = fixture.reconciliation();
      ledger.applyEvidence(evidence, nowEpochMs: 1);

      final duplicate = ledger.applyEvidence(evidence, nowEpochMs: 2);
      expect(duplicate.disposition, LogicalCandidateTransitionDisposition.duplicateIgnored);
      expect(duplicate.record!.phase, LogicalCandidateQuarantinePhase.reconciling);
      expect(duplicate.record!.acceptedEvidence, hasLength(1));

      final conflict = ledger.applyEvidence(
        fixture.reconciliation(evidenceFingerprint: _fp('conflicting-sequence-one')),
        nowEpochMs: 3,
      );
      expect(conflict.disposition, LogicalCandidateTransitionDisposition.rejectedFailClosed);
      expect(conflict.record!.rejectionReason, LogicalCandidateRejectionReason.evidenceSequenceConflict);
      expect(conflict.record!.mustRemainPhysicallyVisibleAt(3), isTrue);
    });

    test('one source evidence identity cannot be replayed under a later sequence', () {
      final fixture = _fixture('cross-sequence-replay');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      final reconciliation = fixture.reconciliation();
      ledger.applyEvidence(reconciliation, nowEpochMs: 1);

      final replay = ledger.applyEvidence(
        fixture.certificate(evidenceFingerprint: reconciliation.evidenceFingerprint),
        nowEpochMs: 2,
      );

      expect(replay.disposition, LogicalCandidateTransitionDisposition.rejectedFailClosed);
      expect(replay.record!.phase, LogicalCandidateQuarantinePhase.rejected);
      expect(replay.record!.rejectionReason, LogicalCandidateRejectionReason.evidenceSequenceConflict);
      expect(replay.record!.mustRemainPhysicallyVisibleAt(2), isTrue);
    });

    test('sequence gaps and certificate-before-reconciliation fail closed', () {
      for (final evidence in <LogicalCandidateEvidence>[
        _fixture('gap').reconciliation(sequence: 2),
        _fixture('certificate-first').certificate(sequence: 1),
      ]) {
        final fixture = evidence.targetLogicalId == _fixture('gap').nomination.targetLogicalId
            ? _fixture('gap')
            : _fixture('certificate-first');
        final ledger = LogicalCandidateQuarantineLedger.empty();
        ledger.nominate(fixture.nomination, nowEpochMs: 10, quarantineDurationMs: 100);

        final result = ledger.applyEvidence(evidence, nowEpochMs: 11);

        expect(result.disposition, LogicalCandidateTransitionDisposition.rejectedFailClosed);
        expect(result.record!.canJoinLogicalProjection, isFalse);
      }
    });

    test('context drift in participant set, service, or account rejects rather than adapting', () {
      for (final mismatch in <String>['participants', 'service', 'account']) {
        final fixture = _fixture('context-$mismatch');
        final ledger = LogicalCandidateQuarantineLedger.empty();
        ledger.nominate(fixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
        final evidence = LogicalCandidateEvidence.reconciliation(
          candidate: fixture.nomination.candidate,
          targetLogicalId: fixture.nomination.targetLogicalId,
          sequence: 1,
          exactParticipantSetFingerprint: mismatch == 'participants'
              ? _fp('changed-participants')
              : fixture.nomination.exactParticipantSetFingerprint,
          serviceFingerprint: mismatch == 'service' ? _fp('changed-service') : fixture.nomination.serviceFingerprint,
          accountFingerprint: mismatch == 'account' ? _fp('changed-account') : fixture.nomination.accountFingerprint,
          evidenceFingerprint: _fp('context-evidence-$mismatch'),
          authorityFingerprint: fixture.reconciliationAuthorityFingerprint,
        );

        final result = ledger.applyEvidence(evidence, nowEpochMs: 1);

        expect(result.record!.rejectionReason, LogicalCandidateRejectionReason.evidenceContextMismatch);
        expect(result.record!.mustRemainPhysicallyVisibleAt(1), isTrue);
      }
    });

    test('evidence for an unknown candidate cannot create or hide state', () {
      final fixture = _fixture('unknown');
      final ledger = LogicalCandidateQuarantineLedger.empty();

      final result = ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 1);

      expect(result.disposition, LogicalCandidateTransitionDisposition.unknownCandidateVisible);
      expect(result.record, isNull);
      expect(ledger.recordsAt(nowEpochMs: 1), isEmpty);
    });

    test('terminal state cannot be altered by later or replayed evidence', () {
      final fixture = _fixture('terminal');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: 1);
      ledger.applyEvidence(fixture.certificate(), nowEpochMs: 2);

      expect(
        ledger.applyEvidence(fixture.certificate(), nowEpochMs: 3).disposition,
        LogicalCandidateTransitionDisposition.duplicateIgnored,
      );
      final stale = ledger.applyEvidence(fixture.rejection(sequence: 3), nowEpochMs: 4);
      expect(stale.disposition, LogicalCandidateTransitionDisposition.terminalIgnored);
      expect(stale.record!.phase, LogicalCandidateQuarantinePhase.certified);
    });

    test('a conflicting nomination fails active quarantine open and cannot be retried into hiding', () {
      final fixture = _fixture('nomination-conflict');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      final conflicting = _nomination(
        'nomination-conflict',
        candidate: fixture.nomination.candidate,
        exactParticipantSetFingerprint: _fp('other-exact-set'),
      );

      final result = ledger.nominate(conflicting, nowEpochMs: 1, quarantineDurationMs: 100);
      expect(result.disposition, LogicalCandidateTransitionDisposition.rejectedFailClosed);
      expect(result.record!.rejectionReason, LogicalCandidateRejectionReason.nominationConflict);
      expect(result.record!.mustRemainPhysicallyVisibleAt(1), isTrue);

      final replay = ledger.nominate(fixture.nomination, nowEpochMs: 2, quarantineDurationMs: 100);
      expect(replay.disposition, LogicalCandidateTransitionDisposition.duplicateIgnored);
      expect(replay.record!.mustRemainPhysicallyVisibleAt(2), isTrue);
    });
  });

  group('durable privacy-safe reconstruction', () {
    test('record ordering and restart reconstruction are deterministic', () {
      final fixtures = <_CandidateFixture>[_fixture('charlie'), _fixture('alpha'), _fixture('bravo')];
      final forward = LogicalCandidateQuarantineLedger.empty();
      final reverse = LogicalCandidateQuarantineLedger.empty();
      for (final fixture in fixtures) {
        forward.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 100);
        forward.applyEvidence(fixture.reconciliation(), nowEpochMs: 101);
      }
      for (final fixture in fixtures.reversed) {
        reverse.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 100);
        reverse.applyEvidence(fixture.reconciliation(), nowEpochMs: 101);
      }

      final forwardJson = forward.toJson(nowEpochMs: 102);
      final reverseJson = reverse.toJson(nowEpochMs: 102);
      expect(jsonEncode(reverseJson), jsonEncode(forwardJson));
      expect(reverse.stableFingerprintAt(nowEpochMs: 102), forward.stableFingerprintAt(nowEpochMs: 102));

      final restarted = LogicalCandidateQuarantineLedger.fromJson(
        jsonDecode(jsonEncode(forwardJson)) as Map<String, dynamic>,
        nowEpochMs: 102,
      );
      expect(jsonEncode(restarted.toJson(nowEpochMs: 102)), jsonEncode(forwardJson));
      expect(restarted.stableFingerprintAt(nowEpochMs: 102), forward.stableFingerprintAt(nowEpochMs: 102));
    });

    test('serialized state retains fingerprints only and no raw discovery material', () {
      const rawCandidate = 'raw-provider-guid@example.test';
      const rawParticipant = '+1-555-0100';
      const rawTitle = 'Private Family Title';
      final fixture = _fixture(
        'privacy',
        candidate: PhysicalConversationRef.fromStablePhysicalGuid(rawCandidate),
        exactParticipantSetFingerprint: _fp(rawParticipant),
      );
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 1, quarantineDurationMs: 10);
      final json = ledger.toJson(nowEpochMs: 1);
      final encoded = jsonEncode(json);

      expect(encoded, isNot(contains(rawCandidate)));
      expect(encoded, isNot(contains(rawParticipant)));
      expect(encoded, isNot(contains(rawTitle)));
      expect(encoded.toLowerCase(), isNot(contains('title')));
      _expectFingerprintFieldsAreOpaque(json);
    });

    test('same exact-set digest creates no transitive enrollment', () {
      final exactSet = _fp('shared-exact-set');
      final first = _fixture('same-set-first', exactParticipantSetFingerprint: exactSet);
      final second = _fixture('same-set-second', exactParticipantSetFingerprint: exactSet);
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(first.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      ledger.nominate(second.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      ledger.applyEvidence(first.reconciliation(), nowEpochMs: 1);
      ledger.applyEvidence(first.certificate(), nowEpochMs: 2);

      expect(ledger.recordFor(first.nomination.candidate, nowEpochMs: 2)!.canJoinLogicalProjection, isTrue);
      final unrelated = ledger.recordFor(second.nomination.candidate, nowEpochMs: 2)!;
      expect(unrelated.phase, LogicalCandidateQuarantinePhase.nominated);
      expect(unrelated.canJoinLogicalProjection, isFalse);
    });

    test('malformed, forged, duplicate, or unbounded persisted records fail closed', () {
      final fixture = _fixture('tamper');
      final ledger = LogicalCandidateQuarantineLedger.empty();
      ledger.nominate(fixture.nomination, nowEpochMs: 100, quarantineDurationMs: 50);
      final original = ledger.toJson(nowEpochMs: 100);

      Map<String, dynamic> clone() => jsonDecode(jsonEncode(original)) as Map<String, dynamic>;

      final duplicate = clone();
      final duplicateRecords = duplicate['records'] as List<dynamic>;
      duplicateRecords.add(jsonDecode(jsonEncode(duplicateRecords.single)));
      expect(() => LogicalCandidateQuarantineLedger.fromJson(duplicate, nowEpochMs: 100), throwsFormatException);

      final unbounded = clone();
      final unboundedRecord = (unbounded['records'] as List<dynamic>).single as Map<String, dynamic>;
      unboundedRecord['quarantineDeadlineEpochMs'] = 100 + LogicalCandidateQuarantineLedger.maxQuarantineDurationMs + 1;
      expect(() => LogicalCandidateQuarantineLedger.fromJson(unbounded, nowEpochMs: 100), throwsFormatException);

      final rawFingerprint = clone();
      final rawRecord = (rawFingerprint['records'] as List<dynamic>).single as Map<String, dynamic>;
      (rawRecord['candidate'] as Map<String, dynamic>)['fingerprint'] = 'raw-provider-guid';
      expect(() => LogicalCandidateQuarantineLedger.fromJson(rawFingerprint, nowEpochMs: 100), throwsFormatException);

      final forgedCertified = clone();
      final forgedRecord = (forgedCertified['records'] as List<dynamic>).single as Map<String, dynamic>;
      forgedRecord['phase'] = LogicalCandidateQuarantinePhase.certified.name;
      expect(() => LogicalCandidateQuarantineLedger.fromJson(forgedCertified, nowEpochMs: 100), throwsFormatException);

      final certifiedFixture = _fixture('forged-authority');
      final certifiedLedger = LogicalCandidateQuarantineLedger.empty();
      certifiedLedger.nominate(certifiedFixture.nomination, nowEpochMs: 0, quarantineDurationMs: 100);
      certifiedLedger.applyEvidence(certifiedFixture.reconciliation(), nowEpochMs: 1);
      certifiedLedger.applyEvidence(certifiedFixture.certificate(), nowEpochMs: 2);
      final forgedAuthority = jsonDecode(jsonEncode(certifiedLedger.toJson(nowEpochMs: 2))) as Map<String, dynamic>;
      final certifiedRecord = (forgedAuthority['records'] as List<dynamic>).single as Map<String, dynamic>;
      certifiedRecord['certificateAuthorityFingerprint'] = certifiedRecord['nominatorFingerprint'];
      final accepted = certifiedRecord['acceptedEvidence'] as List<dynamic>;
      (accepted.last as Map<String, dynamic>)['authorityFingerprint'] = certifiedRecord['nominatorFingerprint'];
      expect(() => LogicalCandidateQuarantineLedger.fromJson(forgedAuthority, nowEpochMs: 2), throwsFormatException);
    });

    test('many round trips preserve state and never promote an active candidate', () {
      for (var index = 0; index < 96; index += 1) {
        final fixture = _fixture('round-trip-$index');
        final ledger = LogicalCandidateQuarantineLedger.empty();
        final start = index * 1000;
        ledger.nominate(fixture.nomination, nowEpochMs: start, quarantineDurationMs: 100);
        if (index.isEven) ledger.applyEvidence(fixture.reconciliation(), nowEpochMs: start + 1);

        final encoded = jsonEncode(ledger.toJson(nowEpochMs: start + 2));
        final restored = LogicalCandidateQuarantineLedger.fromJson(
          jsonDecode(encoded) as Map<String, dynamic>,
          nowEpochMs: start + 2,
        );
        final record = restored.recordFor(fixture.nomination.candidate, nowEpochMs: start + 2)!;

        expect(record.canJoinLogicalProjection, isFalse);
        expect(jsonEncode(restored.toJson(nowEpochMs: start + 2)), encoded);
      }
    });
  });
}

String _fp(String value) => sha256.convert(utf8.encode('candidate-test-v1\u0000$value')).toString();

LogicalCandidateNomination _nomination(
  String seed, {
  PhysicalConversationRef? candidate,
  String? exactParticipantSetFingerprint,
  String? nominatorFingerprint,
}) => LogicalCandidateNomination(
  candidate: candidate ?? PhysicalConversationRef.fromStablePhysicalGuid('candidate-$seed'),
  targetLogicalId: LogicalConversationId.certified('target-$seed'),
  exactParticipantSetFingerprint: exactParticipantSetFingerprint ?? _fp('participants-$seed'),
  serviceFingerprint: _fp('service-$seed'),
  accountFingerprint: _fp('account-$seed'),
  nominationEvidenceFingerprint: _fp('nomination-evidence-$seed'),
  nominatorFingerprint: nominatorFingerprint ?? _fp('nominator-$seed'),
);

_CandidateFixture _fixture(
  String seed, {
  PhysicalConversationRef? candidate,
  String? exactParticipantSetFingerprint,
  String? nominatorFingerprint,
  String? reconciliationAuthorityFingerprint,
}) => _CandidateFixture(
  seed,
  _nomination(
    seed,
    candidate: candidate,
    exactParticipantSetFingerprint: exactParticipantSetFingerprint,
    nominatorFingerprint: nominatorFingerprint,
  ),
  reconciliationAuthorityFingerprint ?? _fp('reconciler-$seed'),
  _fp('certifier-$seed'),
  _fp('certificate-$seed'),
);

class _CandidateFixture {
  const _CandidateFixture(
    this.seed,
    this.nomination,
    this.reconciliationAuthorityFingerprint,
    this.certificateAuthorityFingerprint,
    this.certificateFingerprint,
  );

  final String seed;
  final LogicalCandidateNomination nomination;
  final String reconciliationAuthorityFingerprint;
  final String certificateAuthorityFingerprint;
  final String certificateFingerprint;

  LogicalCandidateEvidence reconciliation({int sequence = 1, String? evidenceFingerprint}) =>
      LogicalCandidateEvidence.reconciliation(
        candidate: nomination.candidate,
        targetLogicalId: nomination.targetLogicalId,
        sequence: sequence,
        exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
        serviceFingerprint: nomination.serviceFingerprint,
        accountFingerprint: nomination.accountFingerprint,
        evidenceFingerprint: evidenceFingerprint ?? _fp('reconciliation-evidence-$seed-$sequence'),
        authorityFingerprint: reconciliationAuthorityFingerprint,
      );

  LogicalCandidateEvidence certificate({int sequence = 2, String? authorityFingerprint, String? evidenceFingerprint}) =>
      LogicalCandidateEvidence.independentCertificate(
        candidate: nomination.candidate,
        targetLogicalId: nomination.targetLogicalId,
        sequence: sequence,
        exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
        serviceFingerprint: nomination.serviceFingerprint,
        accountFingerprint: nomination.accountFingerprint,
        evidenceFingerprint: evidenceFingerprint ?? _fp('certificate-evidence-$seed-$sequence'),
        authorityFingerprint: authorityFingerprint ?? certificateAuthorityFingerprint,
        certificateFingerprint: certificateFingerprint,
      );

  LogicalCandidateEvidence rejection({required int sequence}) => LogicalCandidateEvidence.rejection(
    candidate: nomination.candidate,
    targetLogicalId: nomination.targetLogicalId,
    sequence: sequence,
    exactParticipantSetFingerprint: nomination.exactParticipantSetFingerprint,
    serviceFingerprint: nomination.serviceFingerprint,
    accountFingerprint: nomination.accountFingerprint,
    evidenceFingerprint: _fp('rejection-evidence-$seed-$sequence'),
    authorityFingerprint: _fp('rejector-$seed'),
  );
}

void _expectFingerprintFieldsAreOpaque(Object? value) {
  if (value is List) {
    for (final item in value) {
      _expectFingerprintFieldsAreOpaque(item);
    }
    return;
  }
  if (value is! Map) return;
  for (final entry in value.entries) {
    final key = entry.key.toString();
    final child = entry.value;
    if (key.toLowerCase().contains('fingerprint') && child != null) {
      expect(child, isA<String>());
      expect(child as String, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    _expectFingerprintFieldsAreOpaque(child);
  }
}
